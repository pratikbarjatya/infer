(*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd

module F = Format
module L = Logging

type t =
  | AccessPath of AccessPath.Raw.t
  | UnaryOperator of Unop.t * t * Typ.t option
  | BinaryOperator of Binop.t * t * t
  | Exception of t
  | Closure of Typ.Procname.t * (AccessPath.base * t) list
  | Constant of Const.t
  | Cast of Typ.t * t
  | Sizeof of Typ.t * t option
[@@deriving compare]

let rec pp fmt = function
  | AccessPath access_path ->
      AccessPath.Raw.pp fmt access_path
  | UnaryOperator (op, e, _) ->
      F.fprintf fmt "%s%a" (Unop.str op) pp e
  | BinaryOperator(op, e1, e2) ->
      F.fprintf fmt "%a %s %a" pp e1 (Binop.str Pp.text op) pp e2
  | Exception e ->
      F.fprintf fmt "exception %a" pp e
  | Closure (pname, _) ->
      F.fprintf fmt "closure(%a)" Typ.Procname.pp pname
  | Constant c ->
      (Const.pp Pp.text) fmt c
  | Cast (typ, e) ->
      F.fprintf fmt "(%a) %a" (Typ.pp_full Pp.text) typ pp e
  | Sizeof (typ, length) ->
      let pp_length fmt = Option.iter ~f:(F.fprintf fmt "[%a]" pp) in
      F.fprintf fmt "sizeof(%a%a)" (Typ.pp_full Pp.text) typ pp_length length

let get_access_paths exp0 =
  let rec get_access_paths_ exp acc =
    match exp with
    | AccessPath ap ->
        ap :: acc
    | Cast (_, e) | UnaryOperator (_, e, _) | Exception e | Sizeof (_, Some e) ->
        get_access_paths_ e acc
    | BinaryOperator (_, e1, e2) ->
        get_access_paths_ e1 acc
        |> get_access_paths_ e2
    | Closure _ | Constant _ | Sizeof _ ->
        acc in
  get_access_paths_ exp0 []

(* convert an SIL expression into an HIL expression. the [f_resolve_id] function should map an SSA
   temporary variable to the access path it represents. evaluating the HIL expression should
   produce the same result as evaluating the SIL expression and replacing the temporary variables
   using [f_resolve_id] *)
let rec of_sil ~f_resolve_id (exp : Exp.t) typ = match exp with
  | Var id ->
      let ap = match f_resolve_id (Var.of_id id) with
        | Some access_path -> access_path
        | None -> AccessPath.of_id id typ in
      AccessPath ap
  | UnOp (op, e, typ_opt) ->
      UnaryOperator (op, of_sil ~f_resolve_id e typ, typ_opt)
  | BinOp (op, e0, e1) ->
      BinaryOperator (op, of_sil ~f_resolve_id e0 typ, of_sil ~f_resolve_id e1 typ)
  | Exn e ->
      Exception (of_sil ~f_resolve_id e typ)
  | Const c ->
      Constant c
  | Cast (cast_typ, e) ->
      Cast (cast_typ, of_sil ~f_resolve_id e typ)
  | Sizeof (sizeof_typ, dynamic_length, _) ->
      Sizeof (sizeof_typ, Option.map ~f:(fun e -> of_sil ~f_resolve_id e typ) dynamic_length)
  | Closure closure ->
      let environment =
        List.map
          ~f:(fun (value, pvar, typ) ->
              AccessPath.base_of_pvar pvar typ, of_sil ~f_resolve_id value typ)
          closure.captured_vars in
      Closure (closure.name, environment)
  | Lvar _ | Lfield _ | Lindex _ ->
      match AccessPath.of_lhs_exp exp typ ~f_resolve_id with
      | Some access_path ->
          AccessPath access_path
      | None ->
          failwithf "Couldn't convert var/field/index expression %a to access path" Exp.pp exp
