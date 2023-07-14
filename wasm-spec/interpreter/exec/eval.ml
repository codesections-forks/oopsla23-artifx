open Ast
open Pack
open Source
open Types
open Value
open Instance


(* Errors *)

module Link = Error.Make ()
module Trap = Error.Make ()
module Exception = Error.Make ()
module Suspension = Error.Make ()
module Exhaustion = Error.Make ()
module Crash = Error.Make ()

exception Link = Link.Error
exception Trap = Trap.Error
exception Exception = Exception.Error
exception Suspension = Suspension.Error
exception Exhaustion = Exhaustion.Error
exception Crash = Crash.Error (* failure that cannot happen in valid code *)

let table_error at = function
  | Table.Bounds -> "out of bounds table access"
  | Table.SizeOverflow -> "table size overflow"
  | Table.SizeLimit -> "table size limit reached"
  | Table.Type -> Crash.error at "type mismatch at table access"
  | exn -> raise exn

let memory_error at = function
  | Memory.Bounds -> "out of bounds memory access"
  | Memory.SizeOverflow -> "memory size overflow"
  | Memory.SizeLimit -> "memory size limit reached"
  | Memory.Type -> Crash.error at "type mismatch at memory access"
  | exn -> raise exn

let numeric_error at = function
  | Ixx.Overflow -> "integer overflow"
  | Ixx.DivideByZero -> "integer divide by zero"
  | Ixx.InvalidConversion -> "invalid conversion to integer"
  | Value.TypeError (i, v, t) ->
    Crash.error at
      ("type error, expected " ^ string_of_num_type t ^ " as operand " ^
       string_of_int i ^ ", got " ^ string_of_num_type (type_of_num v))
  | exn -> raise exn


(* Administrative Expressions & Continuations *)

type 'a stack = 'a list

type frame =
{
  inst : module_inst;
  locals : value option ref list;
}

type code = value stack * admin_instr list

and admin_instr = admin_instr' phrase
and admin_instr' =
  | Plain of instr'
  | Refer of ref_
  | Invoke of func_inst
  | Label of int32 * instr list * code
  | Frame of int32 * frame * code
  | Handle of (tag_inst * idx) list option * code
  | Trapping of string
  | Throwing of tag_inst * value stack
  | Rethrowing of int32 * (admin_instr -> admin_instr)
  | Suspending of tag_inst * value stack * ctxt
  | Returning of value stack
  | ReturningInvoke of value stack * func_inst
  | Breaking of int32 * value stack
  | Catch of int32 * (Tag.t * instr list) list * instr list option * code
  | Caught of int32 * Tag.t * value stack * code
  | Delegate of int32 * code
  | Delegating of int32 * Tag.t * value stack

and ctxt = code -> code

type cont = int32 * ctxt  (* TODO: represent type properly *)
type ref_ += ContRef of cont option ref

let () =
  let type_of_ref' = !Value.type_of_ref' in
  Value.type_of_ref' := function
    | ContRef _ -> BotHT  (* TODO *)
    | r -> type_of_ref' r

let () =
  let string_of_ref' = !Value.string_of_ref' in
  Value.string_of_ref' := function
    | ContRef _ -> "cont"
    | r -> string_of_ref' r

let plain e = Plain e.it @@ e.at

let is_jumping e =
  match e.it with
  | Trapping _ | Throwing _ | Suspending _
  | Returning _ | ReturningInvoke _ | Breaking _ ->
    true
  | _ -> false

let compose (vs1, es1) (vs2, es2) = vs1 @ vs2, es1 @ es2


(* Configurations *)

type config =
{
  frame : frame;
  code : code;
  budget : int;  (* to model stack overflow *)
}

let frame inst locals = {inst; locals}
let config inst vs es =
  {frame = frame inst []; code = vs, es; budget = !Flags.budget}

let lookup category list x =
  try Lib.List32.nth list x.it with Failure _ ->
    Crash.error x.at ("undefined " ^ category ^ " " ^ Int32.to_string x.it)

let type_ (inst : module_inst) x = lookup "type" inst.types x
let func (inst : module_inst) x = lookup "function" inst.funcs x
let table (inst : module_inst) x = lookup "table" inst.tables x
let memory (inst : module_inst) x = lookup "memory" inst.memories x
let global (inst : module_inst) x = lookup "global" inst.globals x
let tag (inst : module_inst) x = lookup "tag" inst.tags x
let elem (inst : module_inst) x = lookup "element segment" inst.elems x
let data (inst : module_inst) x = lookup "data segment" inst.datas x
let local (frame : frame) x = lookup "local" frame.locals x

let func_type (inst : module_inst) x = as_func_def_type (def_of (type_ inst x))
let cont_type (inst : module_inst) x = as_cont_def_type (def_of (type_ inst x))

let any_ref (inst : module_inst) x i at =
  try Table.load (table inst x) i with Table.Bounds ->
    Trap.error at ("undefined element " ^ Int32.to_string i)

let func_ref (inst : module_inst) x i at =
  match any_ref inst x i at with
  | FuncRef f -> f
  | NullRef _ -> Trap.error at ("uninitialized element " ^ Int32.to_string i)
  | _ -> Crash.error at ("type mismatch for element " ^ Int32.to_string i)

let block_type (inst : module_inst) bt at =
  match bt with
  | ValBlockType None -> InstrT ([], [], [])
  | ValBlockType (Some t) -> InstrT ([], [dyn_val_type inst.types t], [])
  | VarBlockType x ->
    let FuncT (ts1, ts2) = func_type inst x in InstrT (ts1, ts2, [])

let take n (vs : 'a stack) at =
  try Lib.List32.take n vs with Failure _ -> Crash.error at "stack underflow"

let drop n (vs : 'a stack) at =
  try Lib.List32.drop n vs with Failure _ -> Crash.error at "stack underflow"

let split n (vs : 'a stack) at = take n vs at, drop n vs at


(* Evaluation *)

(*
 * Conventions:
 *   e  : instr
 *   v  : value
 *   es : instr list
 *   vs : value stack
 *   c : config
 *)

let mem_oob frame x i n =
  I64.gt_u (I64.add (I64_convert.extend_i32_u i) (I64_convert.extend_i32_u n))
    (Memory.bound (memory frame.inst x))

let data_oob frame x i n =
  I64.gt_u (I64.add (I64_convert.extend_i32_u i) (I64_convert.extend_i32_u n))
    (Data.size (data frame.inst x))

let table_oob frame x i n =
  I64.gt_u (I64.add (I64_convert.extend_i32_u i) (I64_convert.extend_i32_u n))
    (I64_convert.extend_i32_u (Table.size (table frame.inst x)))

let elem_oob frame x i n =
  I64.gt_u (I64.add (I64_convert.extend_i32_u i) (I64_convert.extend_i32_u n))
    (I64_convert.extend_i32_u (Elem.size (elem frame.inst x)))

let rec step (c : config) : config =
  let vs, es = c.code in
  let e = List.hd es in
  let vs', es' =
    match e.it, vs with
    | Plain e', vs ->
      (match e', vs with
       | Unreachable, vs ->
        vs, [Trapping "unreachable executed" @@ e.at]

      | Nop, vs ->
        vs, []

      | Block (bt, es'), vs ->
        let InstrT (ts1, ts2, _xs) = block_type c.frame.inst bt e.at in
        let n1 = Lib.List32.length ts1 in
        let n2 = Lib.List32.length ts2 in
        let args, vs' = take n1 vs e.at, drop n1 vs e.at in
        vs', [Label (n2, [], (args, List.map plain es')) @@ e.at]

      | Loop (bt, es'), vs ->
        let InstrT (ts1, ts2, _xs) = block_type c.frame.inst bt e.at in
        let n1 = Lib.List32.length ts1 in
        let args, vs' = take n1 vs e.at, drop n1 vs e.at in
        vs', [Label (n1, [e' @@ e.at], (args, List.map plain es')) @@ e.at]

      | If (bt, es1, es2), Num (I32 i) :: vs' ->
        if i = 0l then
          vs', [Plain (Block (bt, es2)) @@ e.at]
        else
          vs', [Plain (Block (bt, es1)) @@ e.at]

      | Throw x, vs ->
        let tagt = tag c.frame.inst x in
        let TagT x' = Tag.type_of tagt in
        let FuncT (ts, _) = as_func_def_type (def_of (as_dyn_var x')) in
        let vs0, vs' = split (Lib.List32.length ts) vs e.at in
        vs', [Throwing (tagt, vs0) @@ e.at]

      | Rethrow x, vs ->
        vs, [Rethrowing (x.it, fun e -> e) @@ e.at]

      | TryCatch (bt, es', cts, ca), vs ->
        let InstrT (ts1, ts2, _xs) = block_type c.frame.inst bt e.at in
        let n1 = Lib.List32.length ts1 in
        let n2 = Lib.List32.length ts2 in
        let args, vs' = take n1 vs e.at, drop n1 vs e.at in
        let cts' = List.map (fun (x, es'') -> ((tag c.frame.inst x), es'')) cts in
        vs', [Label (n2, [], ([], [Catch (n2, cts', ca, (args, List.map plain es')) @@ e.at])) @@ e.at]

      | TryDelegate (bt, es', x), vs ->
        let InstrT (ts1, ts2, _xs) = block_type c.frame.inst bt e.at in
        let n1 = Lib.List32.length ts1 in
        let n2 = Lib.List32.length ts2 in
        let args, vs' = take n1 vs e.at, drop n1 vs e.at in
        vs', [Label (n2, [], ([], [Delegate (x.it, (args, List.map plain es')) @@ e.at])) @@ e.at]

      | Br x, vs ->
        [], [Breaking (x.it, vs) @@ e.at]

      | BrIf x, Num (I32 i) :: vs' ->
        if i = 0l then
          vs', []
        else
          vs', [Plain (Br x) @@ e.at]

      | BrTable (xs, x), Num (I32 i) :: vs' ->
        if I32.ge_u i (Lib.List32.length xs) then
          vs', [Plain (Br x) @@ e.at]
        else
          vs', [Plain (Br (Lib.List32.nth xs i)) @@ e.at]

      | BrOnNull x, Ref r :: vs' ->
        (match r with
        | NullRef _ ->
          vs', [Plain (Br x) @@ e.at]
        | _ ->
          Ref r :: vs', []
        )

      | BrOnNonNull x, Ref r :: vs' ->
        (match r with
        | NullRef _ ->
          vs', []
        | _ ->
          Ref r :: vs', [Plain (Br x) @@ e.at]
        )

      | Return, vs ->
        [], [Returning vs @@ e.at]

      | Call x, vs ->
        vs, [Invoke (func c.frame.inst x) @@ e.at]

      | CallRef _x, Ref (NullRef _) :: vs ->
        vs, [Trapping "null function reference" @@ e.at]

      | CallRef _x, Ref (FuncRef f) :: vs ->
        vs, [Invoke f @@ e.at]

      | CallIndirect (x, y), Num (I32 i) :: vs ->
        let f = func_ref c.frame.inst x i e.at in
        if
          Match.eq_func_type [] (func_type c.frame.inst y) (Func.type_of f)
        then
          vs, [Invoke f @@ e.at]
        else
          vs, [Trapping "indirect call type mismatch" @@ e.at]

      | ReturnCallRef _x, Ref (NullRef _) :: vs ->
        vs, [Trapping "null function reference" @@ e.at]

      | ReturnCallRef x, vs ->
        (match (step {c with code = (vs, [Plain (CallRef x) @@ e.at])}).code with
        | vs', [{it = Invoke a; at}] -> vs', [ReturningInvoke (vs', a) @@ at]
        | vs', [{it = Trapping s; at}] -> vs', [Trapping s @@ at]
        | _ -> assert false
        )

      | ContNew x, Ref (NullRef _) :: vs ->
        vs, [Trapping "null function reference" @@ e.at]

      | ContNew x, Ref (FuncRef f) :: vs ->
        let FuncT (ts, _) = Func.type_of f in
        let ctxt code = compose code ([], [Invoke f @@ e.at]) in
        Ref (ContRef (ref (Some (Lib.List32.length ts, ctxt)))) :: vs, []

      | ContBind (x, y), Ref (NullRef _) :: vs ->
        vs, [Trapping "null continuation reference" @@ e.at]

      | ContBind (x, y), Ref (ContRef {contents = None}) :: vs ->
        vs, [Trapping "continuation already consumed" @@ e.at]

      | ContBind (x, y), Ref (ContRef ({contents = Some (n, ctxt)} as cont)) :: vs ->
        let ContT z = cont_type c.frame.inst y in
        let FuncT (ts', _) = as_func_def_type (def_of (as_dyn_var z)) in
        let args, vs' =
          try split (Int32.sub n (Lib.List32.length ts')) vs e.at
          with Failure _ -> Crash.error e.at "type mismatch at continuation bind"
        in
        cont := None;
        let ctxt' code = ctxt (compose code (args, [])) in
        Ref (ContRef (ref (Some (Int32.sub n (Lib.List32.length args), ctxt')))) :: vs', []

      | Suspend x, vs ->
        let tagt = tag c.frame.inst x in
        let TagT x' = Tag.type_of tagt in
        let FuncT (ts, _) = as_func_def_type (def_of (as_dyn_var x')) in
        let args, vs' = split (Lib.List32.length ts) vs e.at in
        vs', [Suspending (tagt, args, fun code -> code) @@ e.at]

      | Resume (x, xls), Ref (NullRef _) :: vs ->
        vs, [Trapping "null continuation reference" @@ e.at]

      | Resume (x, xls), Ref (ContRef {contents = None}) :: vs ->
        vs, [Trapping "continuation already consumed" @@ e.at]

      | Resume (x, xls), Ref (ContRef ({contents = Some (n, ctxt)} as cont)) :: vs ->
        let hs = List.map (fun (x, l) -> tag c.frame.inst x, l) xls in
        let args, vs' = split n vs e.at in
        cont := None;
        vs', [Handle (Some hs, ctxt (args, [])) @@ e.at]

      | ResumeThrow (x, y, xls), Ref (NullRef _) :: vs ->
        vs, [Trapping "null continuation reference" @@ e.at]

      | ResumeThrow (x, y, xls), Ref (ContRef {contents = None}) :: vs ->
        vs, [Trapping "continuation already consumed" @@ e.at]

      | ResumeThrow (x, y, xls), Ref (ContRef ({contents = Some (n, ctxt)} as cont)) :: vs ->
        let tagt = tag c.frame.inst y in
        let TagT x' = Tag.type_of tagt in
        let FuncT (ts, _) = as_func_def_type (def_of (as_dyn_var x')) in
        let hs = List.map (fun (x, l) -> tag c.frame.inst x, l) xls in
        let args, vs' = split (Lib.List32.length ts) vs e.at in
        cont := None;
        vs', [Handle (Some hs, ctxt (args, [Plain (Throw x) @@ e.at])) @@ e.at]

      | Barrier (bt, es'), vs ->
        let InstrT (ts1, _, _xs) = block_type c.frame.inst bt e.at in
        let args, vs' = split (Lib.List32.length ts1) vs e.at in
        vs', [
          Handle (None,
            (args, [Plain (Block (bt, es')) @@ e.at])
          ) @@ e.at
        ]

      | ReturnCall x, vs ->
        (match (step {c with code = (vs, [Plain (Call x) @@ e.at])}).code with
        | vs', [{it = Invoke a; at}] -> vs', [ReturningInvoke (vs', a) @@ at]
        | _ -> assert false
        )

      | ReturnCallIndirect (x, y), vs ->
        (match
          (step {c with code = (vs, [Plain (CallIndirect (x, y)) @@ e.at])}).code
        with
        | vs', [{it = Invoke a; at}] -> vs', [ReturningInvoke (vs', a) @@ at]
        | vs', [{it = Trapping s; at}] -> vs', [Trapping s @@ at]
        | _ -> assert false
        )

      | Drop, v :: vs' ->
        vs', []

      | Select _, Num (I32 i) :: v2 :: v1 :: vs' ->
        if i = 0l then
          v2 :: vs', []
        else
          v1 :: vs', []

      | LocalGet x, vs ->
        (match !(local c.frame x) with
        | Some v ->
          v :: vs, []
        | None ->
          Crash.error e.at "read of uninitialized local"
        )

      | LocalSet x, v :: vs' ->
        local c.frame x := Some v;
        vs', []

      | LocalTee x, v :: vs' ->
        local c.frame x := Some v;
        v :: vs', []

      | GlobalGet x, vs ->
        Global.load (global c.frame.inst x) :: vs, []

      | GlobalSet x, v :: vs' ->
        (try Global.store (global c.frame.inst x) v; vs', []
        with Global.NotMutable -> Crash.error e.at "write to immutable global"
           | Global.Type -> Crash.error e.at "type mismatch at global write")

      | TableGet x, Num (I32 i) :: vs' ->
        (try Ref (Table.load (table c.frame.inst x) i) :: vs', []
        with exn -> vs', [Trapping (table_error e.at exn) @@ e.at])

      | TableSet x, Ref r :: Num (I32 i) :: vs' ->
        (try Table.store (table c.frame.inst x) i r; vs', []
        with exn -> vs', [Trapping (table_error e.at exn) @@ e.at])

      | TableSize x, vs ->
        Num (I32 (Table.size (table c.frame.inst x))) :: vs, []

      | TableGrow x, Num (I32 delta) :: Ref r :: vs' ->
        let tab = table c.frame.inst x in
        let old_size = Table.size tab in
        let result =
          try Table.grow tab delta r; old_size
          with Table.SizeOverflow | Table.SizeLimit | Table.OutOfMemory -> -1l
        in Num (I32 result) :: vs', []

      | TableFill x, Num (I32 n) :: Ref r :: Num (I32 i) :: vs' ->
        if table_oob c.frame x i n then
          vs', [Trapping (table_error e.at Table.Bounds) @@ e.at]
        else if n = 0l then
          vs', []
        else
          let _ = assert (I32.lt_u i 0xffff_ffffl) in
          vs', List.map (Lib.Fun.flip (@@) e.at) [
            Plain (Const (I32 i @@ e.at));
            Refer r;
            Plain (TableSet x);
            Plain (Const (I32 (I32.add i 1l) @@ e.at));
            Refer r;
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (TableFill x);
          ]

      | TableCopy (x, y), Num (I32 n) :: Num (I32 s) :: Num (I32 d) :: vs' ->
        if table_oob c.frame x d n || table_oob c.frame y s n then
          vs', [Trapping (table_error e.at Table.Bounds) @@ e.at]
        else if n = 0l then
          vs', []
        else if I32.le_u d s then
          vs', List.map (Lib.Fun.flip (@@) e.at) [
            Plain (Const (I32 d @@ e.at));
            Plain (Const (I32 s @@ e.at));
            Plain (TableGet y);
            Plain (TableSet x);
            Plain (Const (I32 (I32.add d 1l) @@ e.at));
            Plain (Const (I32 (I32.add s 1l) @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (TableCopy (x, y));
          ]
        else (* d > s *)
          vs', List.map (Lib.Fun.flip (@@) e.at) [
            Plain (Const (I32 (I32.add d 1l) @@ e.at));
            Plain (Const (I32 (I32.add s 1l) @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (TableCopy (x, y));
            Plain (Const (I32 d @@ e.at));
            Plain (Const (I32 s @@ e.at));
            Plain (TableGet y);
            Plain (TableSet x);
          ]

      | TableInit (x, y), Num (I32 n) :: Num (I32 s) :: Num (I32 d) :: vs' ->
        if table_oob c.frame x d n || elem_oob c.frame y s n then
          vs', [Trapping (table_error e.at Table.Bounds) @@ e.at]
        else if n = 0l then
          vs', []
        else
          let seg = elem c.frame.inst y in
          vs', List.map (Lib.Fun.flip (@@) e.at) [
            Plain (Const (I32 d @@ e.at));
            Refer (Elem.load seg s);
            Plain (TableSet x);
            Plain (Const (I32 (I32.add d 1l) @@ e.at));
            Plain (Const (I32 (I32.add s 1l) @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (TableInit (x, y));
          ]

      | ElemDrop x, vs ->
        let seg = elem c.frame.inst x in
        Elem.drop seg;
        vs, []

      | Load {offset; ty; pack; _}, Num (I32 i) :: vs' ->
        let mem = memory c.frame.inst (0l @@ e.at) in
        let a = I64_convert.extend_i32_u i in
        let t = dyn_num_type [] ty in
        (try
          let n =
            match pack with
            | None -> Memory.load_num mem a offset t
            | Some (sz, ext) -> Memory.load_num_packed sz ext mem a offset t
          in Num n :: vs', []
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at])

      | Store {offset; pack; _}, Num n :: Num (I32 i) :: vs' ->
        let mem = memory c.frame.inst (0l @@ e.at) in
        let a = I64_convert.extend_i32_u i in
        (try
          (match pack with
          | None -> Memory.store_num mem a offset n
          | Some sz -> Memory.store_num_packed sz mem a offset n
          );
          vs', []
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at]);

      | VecLoad {offset; ty; pack; _}, Num (I32 i) :: vs' ->
        let mem = memory c.frame.inst (0l @@ e.at) in
        let a = I64_convert.extend_i32_u i in
        let t = dyn_vec_type [] ty in
        (try
          let v =
            match pack with
            | None -> Memory.load_vec mem a offset t
            | Some (sz, ext) -> Memory.load_vec_packed sz ext mem a offset t
          in Vec v :: vs', []
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at])

      | VecStore {offset; _}, Vec v :: Num (I32 i) :: vs' ->
        let mem = memory c.frame.inst (0l @@ e.at) in
        let addr = I64_convert.extend_i32_u i in
        (try
          Memory.store_vec mem addr offset v;
          vs', []
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at]);

      | VecLoadLane ({offset; ty; pack; _}, j), Vec (V128 v) :: Num (I32 i) :: vs' ->
        let mem = memory c.frame.inst (0l @@ e.at) in
        let addr = I64_convert.extend_i32_u i in
        (try
          let v =
            match pack with
            | Pack8 ->
              V128.I8x16.replace_lane j v
                (I32Num.of_num 0 (Memory.load_num_packed Pack8 SX mem addr offset I32T))
            | Pack16 ->
              V128.I16x8.replace_lane j v
                (I32Num.of_num 0 (Memory.load_num_packed Pack16 SX mem addr offset I32T))
            | Pack32 ->
              V128.I32x4.replace_lane j v
                (I32Num.of_num 0 (Memory.load_num mem addr offset I32T))
            | Pack64 ->
              V128.I64x2.replace_lane j v
                (I64Num.of_num 0 (Memory.load_num mem addr offset I64T))
          in Vec (V128 v) :: vs', []
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at])

      | VecStoreLane ({offset; ty; pack; _}, j), Vec (V128 v) :: Num (I32 i) :: vs' ->
        let mem = memory c.frame.inst (0l @@ e.at) in
        let addr = I64_convert.extend_i32_u i in
        (try
          (match pack with
          | Pack8 ->
            Memory.store_num_packed Pack8 mem addr offset (I32 (V128.I8x16.extract_lane_s j v))
          | Pack16 ->
            Memory.store_num_packed Pack16 mem addr offset (I32 (V128.I16x8.extract_lane_s j v))
          | Pack32 ->
            Memory.store_num mem addr offset (I32 (V128.I32x4.extract_lane_s j v))
          | Pack64 ->
            Memory.store_num mem addr offset (I64 (V128.I64x2.extract_lane_s j v))
          );
          vs', []
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at])

      | MemorySize, vs ->
        let mem = memory c.frame.inst (0l @@ e.at) in
        Num (I32 (Memory.size mem)) :: vs, []

      | MemoryGrow, Num (I32 delta) :: vs' ->
        let mem = memory c.frame.inst (0l @@ e.at) in
        let old_size = Memory.size mem in
        let result =
          try Memory.grow mem delta; old_size
          with Memory.SizeOverflow | Memory.SizeLimit | Memory.OutOfMemory -> -1l
        in Num (I32 result) :: vs', []

      | MemoryFill, Num (I32 n) :: Num k :: Num (I32 i) :: vs' ->
        if mem_oob c.frame (0l @@ e.at) i n then
          vs', [Trapping (memory_error e.at Memory.Bounds) @@ e.at]
        else if n = 0l then
          vs', []
        else
          vs', List.map (Lib.Fun.flip (@@) e.at) [
            Plain (Const (I32 i @@ e.at));
            Plain (Const (k @@ e.at));
            Plain (Store
              {ty = Types.I32T; align = 0; offset = 0l; pack = Some Pack8});
            Plain (Const (I32 (I32.add i 1l) @@ e.at));
            Plain (Const (k @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (MemoryFill);
          ]

      | MemoryCopy, Num (I32 n) :: Num (I32 s) :: Num (I32 d) :: vs' ->
        if mem_oob c.frame (0l @@ e.at) s n || mem_oob c.frame (0l @@ e.at) d n then
          vs', [Trapping (memory_error e.at Memory.Bounds) @@ e.at]
        else if n = 0l then
          vs', []
        else if I32.le_u d s then
          vs', List.map (Lib.Fun.flip (@@) e.at) [
            Plain (Const (I32 d @@ e.at));
            Plain (Const (I32 s @@ e.at));
            Plain (Load
              {ty = Types.I32T; align = 0; offset = 0l; pack = Some (Pack8, ZX)});
            Plain (Store
              {ty = Types.I32T; align = 0; offset = 0l; pack = Some Pack8});
            Plain (Const (I32 (I32.add d 1l) @@ e.at));
            Plain (Const (I32 (I32.add s 1l) @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (MemoryCopy);
          ]
        else (* d > s *)
          vs', List.map (Lib.Fun.flip (@@) e.at) [
            Plain (Const (I32 (I32.add d 1l) @@ e.at));
            Plain (Const (I32 (I32.add s 1l) @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (MemoryCopy);
            Plain (Const (I32 d @@ e.at));
            Plain (Const (I32 s @@ e.at));
            Plain (Load
              {ty = Types.I32T; align = 0; offset = 0l; pack = Some (Pack8, ZX)});
            Plain (Store
              {ty = Types.I32T; align = 0; offset = 0l; pack = Some Pack8});
          ]

      | MemoryInit x, Num (I32 n) :: Num (I32 s) :: Num (I32 d) :: vs' ->
        if mem_oob c.frame (0l @@ e.at) d n || data_oob c.frame x s n then
          vs', [Trapping (memory_error e.at Memory.Bounds) @@ e.at]
        else if n = 0l then
          vs', []
        else
          let seg = data c.frame.inst x in
          let a = I64_convert.extend_i32_u s in
          let b = Data.load seg a in
          vs', List.map (Lib.Fun.flip (@@) e.at) [
            Plain (Const (I32 d @@ e.at));
            Plain (Const (I32 (I32.of_int_u (Char.code b)) @@ e.at));
            Plain (Store
              {ty = Types.I32T; align = 0; offset = 0l; pack = Some Pack8});
            Plain (Const (I32 (I32.add d 1l) @@ e.at));
            Plain (Const (I32 (I32.add s 1l) @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (MemoryInit x);
          ]

      | DataDrop x, vs ->
        let seg = data c.frame.inst x in
        Data.drop seg;
        vs, []

      | RefNull t, vs' ->
        Ref (NullRef (dyn_heap_type c.frame.inst.types t)) :: vs', []

      | RefIsNull, Ref r :: vs' ->
        (match r with
        | NullRef _ ->
          Num (I32 1l) :: vs', []
        | _ ->
          Num (I32 0l) :: vs', []
        )

      | RefAsNonNull, Ref r :: vs' ->
        (match r with
        | NullRef _ ->
          vs', [Trapping "null reference" @@ e.at]
        | _ ->
          Ref r :: vs', []
        )

      | RefFunc x, vs' ->
        let f = func c.frame.inst x in
        Ref (FuncRef f) :: vs', []

      | Const n, vs ->
        Num n.it :: vs, []

      | Test testop, Num n :: vs' ->
        (try value_of_bool (Eval_num.eval_testop testop n) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | Compare relop, Num n2 :: Num n1 :: vs' ->
        (try value_of_bool (Eval_num.eval_relop relop n1 n2) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | Unary unop, Num n :: vs' ->
        (try Num (Eval_num.eval_unop unop n) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | Binary binop, Num n2 :: Num n1 :: vs' ->
        (try Num (Eval_num.eval_binop binop n1 n2) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | Convert cvtop, Num n :: vs' ->
        (try Num (Eval_num.eval_cvtop cvtop n) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecConst v, vs ->
        Vec v.it :: vs, []

      | VecTest testop, Vec n :: vs' ->
        (try value_of_bool (Eval_vec.eval_testop testop n) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecUnary unop, Vec n :: vs' ->
        (try Vec (Eval_vec.eval_unop unop n) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecBinary binop, Vec n2 :: Vec n1 :: vs' ->
        (try Vec (Eval_vec.eval_binop binop n1 n2) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecCompare relop, Vec n2 :: Vec n1 :: vs' ->
        (try Vec (Eval_vec.eval_relop relop n1 n2) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecConvert cvtop, Vec n :: vs' ->
        (try Vec (Eval_vec.eval_cvtop cvtop n) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecShift shiftop, Num s :: Vec v :: vs' ->
        (try Vec (Eval_vec.eval_shiftop shiftop v s) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecBitmask bitmaskop, Vec v :: vs' ->
        (try Num (Eval_vec.eval_bitmaskop bitmaskop v) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecTestBits vtestop, Vec n :: vs' ->
        (try value_of_bool (Eval_vec.eval_vtestop vtestop n) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecUnaryBits vunop, Vec n :: vs' ->
        (try Vec (Eval_vec.eval_vunop vunop n) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecBinaryBits vbinop, Vec n2 :: Vec n1 :: vs' ->
        (try Vec (Eval_vec.eval_vbinop vbinop n1 n2) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecTernaryBits vternop, Vec v3 :: Vec v2 :: Vec v1 :: vs' ->
        (try Vec (Eval_vec.eval_vternop vternop v1 v2 v3) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecSplat splatop, Num n :: vs' ->
        (try Vec (Eval_vec.eval_splatop splatop n) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecExtract extractop, Vec v :: vs' ->
        (try Num (Eval_vec.eval_extractop extractop v) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | VecReplace replaceop, Num r :: Vec v :: vs' ->
        (try Vec (Eval_vec.eval_replaceop replaceop v r) :: vs', []
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at])

      | _ ->
        let s1 = string_of_values (List.rev vs) in
        let s2 = string_of_result_type (List.map type_of_value (List.rev vs)) in
        Crash.error e.at
          ("missing or ill-typed operand on stack (" ^ s1 ^ " : " ^ s2 ^ ")")
      )

    | Refer r, vs ->
      Ref r :: vs, []

    | Label (n, es0, (vs', [])), vs ->
      vs' @ vs, []

    | Label (n, es0, (vs', {it = Suspending (tagt, vs1, ctxt); at} :: es')), vs ->
      let ctxt' code = [], [Label (n, es0, compose (ctxt code) (vs', es')) @@ e.at] in
      vs, [Suspending (tagt, vs1, ctxt') @@ at]

    | Label (n, es0, (vs', {it = ReturningInvoke (vs0, f); at} :: es')), vs ->
      vs, [ReturningInvoke (vs0, f) @@ at]

    | Label (n, es0, (vs', {it = Breaking (0l, vs0); at} :: es')), vs ->
      take n vs0 e.at @ vs, List.map plain es0

    | Label (n, es0, (vs', {it = Breaking (k, vs0); at} :: es')), vs ->
      vs, [Breaking (Int32.sub k 1l, vs0) @@ at]

    | Label (n, es0, (vs', e' :: es')), vs when is_jumping e' ->
      vs, [e']

    | Label (n, es0, code'), vs ->
      let c' = step {c with code = code'} in
      vs, [Label (n, es0, c'.code) @@ e.at]

    | Frame (n, frame', (vs', [])), vs ->
      vs' @ vs, []

    | Frame (n, frame', (vs', {it = Trapping msg; at} :: es')), vs ->
      vs, [Trapping msg @@ at]

    | Frame (n, frame', (vs', {it = Throwing (a, vs0); at} :: es')), vs ->
      vs, [Throwing (a, vs0) @@ at]

    | Frame (n, frame', (vs', {it = Suspending (tagt, vs1, ctxt); at} :: es')), vs ->
      let ctxt' code = [], [Frame (n, frame', compose (ctxt code) (vs', es')) @@ e.at] in
      vs, [Suspending (tagt, vs1, ctxt') @@ at]

    | Frame (n, frame', (vs', {it = Returning vs0; at} :: es')), vs ->
      take n vs0 e.at @ vs, []

    | Frame (n, frame', (vs', {it = ReturningInvoke (vs0, f); at} :: es')), vs ->
      let FuncT (ts1, _ts2) = Func.type_of f in
      take (Lib.List32.length ts1) vs0 e.at @ vs, [Invoke f @@ at]

    | Frame (n, frame', code'), vs ->
      let c' = step {frame = frame'; code = code'; budget = c.budget - 1} in
      vs, [Frame (n, frame', c'.code) @@ e.at]

    | Catch (n, cts, ca, (vs', [])), vs ->
      vs' @ vs, []

    | Catch (n, cts, ca, (vs', ({it = Trapping _ | Breaking _ | Returning _ | Delegating _; at} as e) :: es')), vs ->
      vs, [e]

    | Catch (n, cts, ca, (vs', {it = Rethrowing (k, cont); at} :: es')), vs ->
      vs, [Rethrowing (k, (fun e -> Catch (n, cts, ca, (vs', (cont e) :: es')) @@ e.at)) @@ at]

    | Catch (n, (a', es'') :: cts, ca, (vs', {it = Throwing (a, vs0); at} :: es')), vs ->
      if a == a' then
        vs, [Caught (n, a, vs0, (vs0, List.map plain es'')) @@ at]
      else
        vs, [Catch (n, cts, ca, (vs', {it = Throwing (a, vs0); at} :: es')) @@ e.at]

    | Catch (n, [], Some es'', (vs', {it = Throwing (a, vs0); at} :: es')), vs ->
      vs, [Caught (n, a, vs0, (vs0, List.map plain es'')) @@ at]

    | Catch (n, [], None, (vs', {it = Throwing (a, vs0); at} :: es')), vs ->
      vs, [Throwing (a, vs0) @@ at]

    | Catch (n, cts, ca, code'), vs ->
      let c' = step {c with code = code'} in
      vs, [Catch (n, cts, ca, c'.code) @@ e.at]

    | Caught (n, a, vs0, (vs', [])), vs ->
      vs' @ vs, []

    | Caught (n, a, vs0, (vs', ({it = Trapping _ | Breaking _ | Returning _ | Throwing _ | Delegating _; at} as e) :: es')), vs ->
      vs, [e]

    | Caught (n, a, vs0, (vs', {it = Rethrowing (0l, cont); at} :: es')), vs ->
      vs, [Caught (n, a, vs0, (vs', (cont (Throwing (a, vs0) @@ at)) :: es')) @@ e.at]

    | Caught (n, a, vs0, (vs', {it = Rethrowing (k, cont); at} :: es')), vs ->
      vs, [Rethrowing (k, (fun e -> Caught (n, a, vs0, (vs', (cont e) :: es')) @@ e.at)) @@ at]

    | Caught (n, a, vs0, code'), vs ->
      let c' = step {c with code = code'} in
      vs, [Caught (n, a, vs0, c'.code) @@ e.at]

    | Delegate (l, (vs', [])), vs ->
      vs' @ vs, []

    | Delegate (l, (vs', ({it = Trapping _ | Breaking _ | Returning _ | Rethrowing _ | Delegating _; at} as e) :: es')), vs ->
      vs, [e]

    | Delegate (l, (vs', {it = Throwing (a, vs0); at} :: es')), vs ->
      vs, [Delegating (l, a, vs0) @@ e.at]

    | Delegate (l, code'), vs ->
      let c' = step {c with code = code'} in
      vs, [Delegate (l, c'.code) @@ e.at]

    | Invoke f, vs when c.budget = 0 ->
      Exhaustion.error e.at "call stack exhausted"

    | Invoke f, vs ->
      let FuncT (ts1, ts2) = Func.type_of f in
      let n1, n2 = Lib.List32.length ts1, Lib.List32.length ts2 in
      let args, vs' = split n1 vs e.at in
      (match f with
       | Func.AstFunc (_, inst', func) ->
        let {locals; body; _} = func.it in
        let m = Lib.Promise.value inst' in
        let ts = List.map (fun loc -> Types.dyn_val_type m.types loc.it.ltype) locals in
        let locs' = List.(rev (map Option.some args) @ map default_value ts) in
        let frame' = {inst = m; locals = List.map ref locs'} in
        let instr' = [Label (n2, [], ([], List.map plain body)) @@ func.at] in
        vs', [Frame (n2, frame', ([], instr')) @@ e.at]

      | Func.HostFunc (_, f) ->
        (try List.rev (f (List.rev args)) @ vs', []
        with Crash (_, msg) -> Crash.error e.at msg)
      )

    | Handle (hso, (vs', [])), vs ->
      vs' @ vs, []

    | Handle (None, (vs', {it = Suspending _; at} :: es')), vs ->
      vs, [Trapping "barrier hit by suspension" @@ at]

    | Handle (Some hs, (vs', {it = Suspending (tagt, vs1, ctxt); at} :: es')), vs
      when List.mem_assq tagt hs ->
      let TagT x' = Tag.type_of tagt in
      let FuncT (_, ts) = as_func_def_type (def_of (as_dyn_var x')) in
      let ctxt' code = compose (ctxt code) (vs', es') in
      [Ref (ContRef (ref (Some (Lib.List32.length ts, ctxt'))))] @ vs1 @ vs,
      [Plain (Br (List.assq tagt hs)) @@ e.at]

    | Handle (hso, (vs', {it = Suspending (tagt, vs1, ctxt); at} :: es')), vs ->
      let ctxt' code = [], [Handle (hso, compose (ctxt code) (vs', es')) @@ e.at] in
      vs, [Suspending (tagt, vs1, ctxt') @@ at]

    | Handle (hso, (vs', e' :: es')), vs when is_jumping e' ->
      vs, [e']

    | Handle (hso, code'), vs ->
      let c' = step {c with code = code'} in
      vs, [Handle (hso, c'.code) @@ e.at]

    | Rethrowing _, _ ->
      Crash.error e.at "undefined catch label"
    | Delegating _, _ ->
      Crash.error e.at "undefined delegate label"

    | Trapping _, _
    | Throwing _, _
    | Suspending _, _
    | Returning _, _
    | ReturningInvoke _, _
    | Breaking _, _ ->
      assert false

  in {c with code = vs', es' @ List.tl es}


let rec eval (c : config) : value stack =
  match c.code with
  | vs, [] ->
    vs

  | vs, e::_ when is_jumping e ->
    (match e.it with
    | Trapping msg ->  Trap.error e.at msg
    | Throwing _ -> Exception.error e.at "unhandled exception"
    | Suspending _ -> Suspension.error e.at "unhandled tag"
    | Returning _ | ReturningInvoke _ -> Crash.error e.at "undefined frame"
    | Breaking _ -> Crash.error e.at "undefined label"
    | _ -> assert false
    )

  | _ ->
    eval (step c)


(* Functions & Constants *)

let at_func = function
 | Func.AstFunc (_, _, f) -> f.at
 | Func.HostFunc _ -> no_region

let invoke (func : func_inst) (vs : value list) : value list =
  let at = at_func func in
  let FuncT (ts1, _ts2) = Func.type_of func in
  if List.length vs <> List.length ts1 then
    Crash.error at "wrong number of arguments";
  if not (List.for_all2 (fun v -> Match.match_val_type [] (type_of_value v)) vs ts1) then
    Crash.error at "wrong types of arguments";
  let c = config empty_module_inst (List.rev vs) [Invoke func @@ at] in
  try List.rev (eval c) with Stack_overflow ->
    Exhaustion.error at "call stack exhausted"

let eval_const (inst : module_inst) (const : const) : value =
  let c = config inst [] (List.map plain const.it) in
  match eval c with
  | [v] -> v
  | vs -> Crash.error const.at "wrong number of results on stack"


(* Modules *)

let create_type (_ : type_) : type_inst =
  Types.alloc_uninit ()

let create_func (inst : module_inst) (f : func) : func_inst =
  Func.alloc (type_ inst f.it.ftype) (Lib.Promise.make ()) f

let create_table (inst : module_inst) (tab : table) : table_inst =
  let {ttype; tinit} = tab.it in
  let tt = Types.dyn_table_type inst.types ttype in
  let r =
    match eval_const inst tinit with
    | Ref r -> r
    | _ -> Crash.error tinit.at "non-reference table initializer"
  in
  Table.alloc tt r

let create_memory (inst : module_inst) (mem : memory) : memory_inst =
  let {mtype} = mem.it in
  Memory.alloc (Types.dyn_memory_type inst.types mtype)

let create_global (inst : module_inst) (glob : global) : global_inst =
  let {gtype; ginit} = glob.it in
  let v = eval_const inst ginit in
  Global.alloc (Types.dyn_global_type inst.types gtype) v

let create_tag (inst : module_inst) (tag : tag) : tag_inst =
  let {tagtype} = tag.it in
  Tag.alloc (Types.dyn_tag_type inst.types tagtype)

let create_export (inst : module_inst) (ex : export) : export_inst =
  let {name; edesc} = ex.it in
  let ext =
    match edesc.it with
    | FuncExport x -> ExternFunc (func inst x)
    | TableExport x -> ExternTable (table inst x)
    | MemoryExport x -> ExternMemory (memory inst x)
    | GlobalExport x -> ExternGlobal (global inst x)
    | TagExport x -> ExternTag (tag inst x)
  in (name, ext)

let create_elem (inst : module_inst) (seg : elem_segment) : elem_inst =
  let {etype; einit; _} = seg.it in
  Elem.alloc (List.map (fun c -> as_ref (eval_const inst c)) einit)

let create_data (inst : module_inst) (seg : data_segment) : data_inst =
  let {dinit; _} = seg.it in
  Data.alloc dinit


let add_import (m : module_) (ext : extern) (im : import) (inst : module_inst)
  : module_inst =
  let it = Types.extern_type_of_import_type (import_type_of m im) in
  let et = Types.dyn_extern_type inst.types it in
  let et' = extern_type_of inst.types ext in
  if not (Match.match_extern_type [] et' et) then
    Link.error im.at ("incompatible import type for " ^
      "\"" ^ Utf8.encode im.it.module_name ^ "\" " ^
      "\"" ^ Utf8.encode im.it.item_name ^ "\": " ^
      "expected " ^ Types.string_of_extern_type et ^
      ", got " ^ Types.string_of_extern_type et');
  match ext with
  | ExternFunc func -> {inst with funcs = func :: inst.funcs}
  | ExternTable tab -> {inst with tables = tab :: inst.tables}
  | ExternMemory mem -> {inst with memories = mem :: inst.memories}
  | ExternGlobal glob -> {inst with globals = glob :: inst.globals}
  | ExternTag tag -> {inst with tags = tag :: inst.tags}


let init_type (inst : module_inst) (type_ : type_) (x : type_inst) =
  Types.init x (Types.dyn_def_type inst.types type_.it)

let init_func (inst : module_inst) (func : func_inst) =
  match func with
  | Func.AstFunc (_, inst_prom, _) -> Lib.Promise.fulfill inst_prom inst
  | _ -> assert false

let run_elem i elem =
  let at = elem.it.emode.at in
  let x = i @@ at in
  match elem.it.emode.it with
  | Passive -> []
  | Active {index; offset} ->
    offset.it @ [
      Const (I32 0l @@ at) @@ at;
      Const (I32 (Lib.List32.length elem.it.einit) @@ at) @@ at;
      TableInit (index, x) @@ at;
      ElemDrop x @@ at
    ]
  | Declarative ->
    [ElemDrop x @@ at]

let run_data i data =
  let at = data.it.dmode.at in
  let x = i @@ at in
  match data.it.dmode.it with
  | Passive -> []
  | Active {index; offset} ->
    assert (index.it = 0l);
    offset.it @ [
      Const (I32 0l @@ at) @@ at;
      Const (I32 (Int32.of_int (String.length data.it.dinit)) @@ at) @@ at;
      MemoryInit x @@ at;
      DataDrop x @@ at
    ]
  | Declarative -> assert false

let run_start start =
  [Call start.it.sfunc @@ start.at]

let init (m : module_) (exts : extern list) : module_inst =
  let
    { types; imports; tables; memories; globals; funcs; tags;
      exports; elems; datas; start
    } = m.it
  in
  if List.length exts <> List.length imports then
    Link.error m.at "wrong number of imports provided for initialisation";
  let inst0 = {empty_module_inst with types = List.map create_type types} in
  List.iter2 (init_type inst0) types inst0.types;
  let inst1 = List.fold_right2 (add_import m) exts imports inst0 in
  let fs = List.map (create_func inst1) funcs in
  let inst2 = {inst1 with funcs = inst1.funcs @ fs} in
  let inst3 =
    { inst2 with
      tables = inst2.tables @ List.map (create_table inst2) tables;
      memories = inst2.memories @ List.map (create_memory inst2) memories;
      globals = inst2.globals @ List.map (create_global inst2) globals;
      tags = inst2.tags @ List.map (create_tag inst2) tags;
    }
  in
  let inst =
    { inst3 with
      exports = List.map (create_export inst3) exports;
      elems = List.map (create_elem inst3) elems;
      datas = List.map (create_data inst3) datas;
    }
  in
  List.iter (init_func inst) fs;
  let es_elem = List.concat (Lib.List32.mapi run_elem elems) in
  let es_data = List.concat (Lib.List32.mapi run_data datas) in
  let es_start = Lib.Option.get (Lib.Option.map run_start start) [] in
  ignore (eval (config inst [] (List.map plain (es_elem @ es_data @ es_start))));
  inst
