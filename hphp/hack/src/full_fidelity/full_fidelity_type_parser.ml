(**
 * Copyright (c) 2016, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

module Token = Full_fidelity_minimal_token
module Syntax = Full_fidelity_minimal_syntax
module SyntaxKind = Full_fidelity_syntax_kind
module TokenKind = Full_fidelity_token_kind
module SourceText = Full_fidelity_source_text
module SimpleParser = Full_fidelity_simple_parser

open TokenKind
open Syntax

include SimpleParser
include Full_fidelity_parser_helpers.WithParser(SimpleParser)

(* TODO: What about something like for::for? Is that a legal
  type constant?  *)

let rec parse_type_specifier parser =
  (* Strictly speaking, "mixed" is a nullable type specifier. We parse it as
     a simple type specifier here. *)
  let (parser1, token) = next_token parser in
  match Token.kind token with
  | Bool
  | Int
  | Float
  | Num
  | String
  | Arraykey
  | Void
  | Resource
  | Mixed -> (parser1, make_simple_type_specifier (make_token token))
  | This -> parse_simple_type_or_type_constant parser
  | Name -> parse_simple_type_or_type_constant_or_generic parser
  | Self -> parse_remaining_type_constant parser1 (make_token token)
  | QualifiedName -> parse_possible_generic_specifier parser
  | Array -> parse_array_type_specifier parser
  | LeftParen -> parse_tuple_or_closure_type_specifier parser
  | Shape -> parse_shape_specifier parser
  | Question -> parse_nullable_type_specifier parser
  | Classname -> parse_classname_type_specifier parser
  | _ ->
    let parser = with_error parser1 SyntaxError.error1007 in
    (parser, make_error [(make_token token)])

(* SPEC
  type-constant-type-name:
    name  ::  name
    self  ::  name
    this  ::  name
    type-constant-type-name  ::  name
*)

and parse_remaining_type_constant parser left =
  let (parser, separator) = next_token parser in
  let (parser1, right) = next_token_as_name parser in
  if (Token.kind right) = Name then
    begin
      let syntax =
        make_type_constant left (make_token separator) (make_token right) in
      let token = peek_token parser1 in
      if (Token.kind token) = ColonColon then
        parse_remaining_type_constant parser1 syntax
      else
        (parser1, syntax)
    end
  else
    (* ERROR RECOVERY: Assume that the thing following the ::
       that is not a name belongs to the next thing to be
       parsed; treat the name as missing. *)
    let parser = with_error parser1 SyntaxError.error1004 in
    let syntax = make_type_constant
      left (make_token separator) (make_missing()) in
    (parser, syntax)

and parse_simple_type_or_type_constant parser =
  let (parser, name) = next_token parser in
  let token = peek_token parser in
  match Token.kind token with
  | ColonColon -> parse_remaining_type_constant parser (make_token name)
  | _ -> (parser, make_simple_type_specifier (make_token name))

and parse_simple_type_or_type_constant_or_generic parser =
  let parser0 = skip_token parser in
  let token = peek_token parser0 in
  match Token.kind token with
  | LessThan -> parse_possible_generic_specifier parser
  | _ -> parse_simple_type_or_type_constant parser

(* SPEC
  class-interface-trait-specifier:
    qualified-name generic-type-argument-listopt
*)

and parse_possible_generic_specifier parser =
  let (parser, name) = next_token parser in
  let (parser, arguments) = parse_generic_type_argument_list_opt parser in
  if (kind arguments) = SyntaxKind.Missing then
    (parser, make_simple_type_specifier (make_token name))
  else
    (parser, make_generic_type_specifier (make_token name) arguments)

and parse_generic_type_argument_list_opt parser =
  let token = peek_token parser in
  if (Token.kind token) = LessThan then
    parse_generic_type_argument_list parser
  else
    (parser, make_missing())

and parse_type_list parser close_kind =
  let rec aux parser acc =
    let (parser1, token) = next_token parser in
    let kind = Token.kind token in
    if kind = close_kind || kind = EndOfFile then
      (* ERROR RECOVERY: If we're here and we got a close brace then
         the list is empty; we expect at least one type. If we're here
         at the end of the file, then we were expecting one more type. *)
      let parser = with_error parser SyntaxError.error1007 in
      (parser, ((make_missing()) :: acc))
    else if kind = Comma then

      (* ERROR RECOVERY: We're expecting a type but we got a comma.
         Assume the type was missing, eat the comma, and move on.
         TODO: This could be poor recovery. For example:

              function bar (Foo< , int blah)

        Plainly the type is missing, but the comma is not associated with
        the type, it's associated with the formal parameter list.  *)

      let parser = with_error parser1 SyntaxError.error1007 in
      let item = make_list_item (make_missing()) (make_token token) in
      aux parser (item :: acc)
    else
      let (parser, ty) = parse_type_specifier parser in
      let (parser1, token) = next_token parser in
      let kind = Token.kind token in
      if kind = close_kind then
        (parser, (ty :: acc))
      else if kind = Comma then
        let item = make_list_item ty (make_token token) in
        aux parser1 (item :: acc)
      else
        (* ERROR RECOVERY: We were expecting a close brace or comma, but
           got neither. Bail out. Caller will give an error. *)
        (parser, (ty :: acc)) in
  let (parser, types) = aux parser [] in
  (parser, make_list (List.rev types))

and parse_generic_type_argument_list parser =
  let (parser, open_angle) = next_token parser in
  let open_angle = make_token open_angle in
  let (parser, args) = parse_type_list parser GreaterThan in
  let (parser1, close_angle) = next_token parser in
  if (Token.kind close_angle) = GreaterThan then
    let result = make_type_arguments open_angle args (make_token close_angle) in
    (parser1, result)
  else
    (* ERROR RECOVERY: Don't eat the token that is in the place of the
       missing > or ,.  Assume that it is the > that is missing and
       try to parse whatever is coming after the type.  *)
    let parser = with_error parser SyntaxError.error1014 in
    let result = make_type_arguments open_angle args (make_missing()) in
    (parser, result)

and parse_array_type_specifier parser =
  let (parser, array_token) = next_token parser in
  let array_token = make_token array_token in
  let (parser, left_angle) =
    expect_token parser LessThan SyntaxError.error1021 in
  (* ERROR RECOVERY: We could improve error recovery by detecting
     array<,  and marking the key type as missing. *)
  let (parser, key_type) = parse_type_specifier parser in
  let kind = Token.kind (peek_token parser) in
  if kind = GreaterThan then
    let (parser, right_angle) = next_token parser in
    let right_angle = make_token right_angle in
    let result = make_vector_type_specifier array_token
      left_angle key_type right_angle in
    (parser, result)
  else if kind = Comma then
    let (parser, comma) = next_token parser in
    let comma = make_token comma in
    let (parser, value_type) = parse_type_specifier parser in
    let (parser, right_angle) =
      expect_token parser GreaterThan SyntaxError.error1013 in
    let result = make_map_type_specifier array_token left_angle key_type
      comma value_type right_angle in
    (parser, result)
  else
    (* ERROR RECOVERY: Assume that the > is missing and keep going. *)
    let right_angle = make_missing() in
    let result = make_vector_type_specifier array_token
      left_angle key_type right_angle in
    (parser, result)

and parse_tuple_or_closure_type_specifier parser =
  let (parser1, _) = next_token parser in
  let token = peek_token parser1 in
  if (Token.kind token) = Function then
    parse_closure_type_specifier parser
  else
    parse_tuple_type_specifier parser

and parse_closure_type_specifier parser =

  (* SPEC
      closure-type-specifier:
          ( function ( type-specifier-listopt ) : type-specifier )
  *)

  (* TODO: Error recovery is pretty weak here. We could be smarter. *)
  let (parser, olp) = next_token parser in
  let olp = make_token olp in
  let (parser, fnc) = next_token parser in
  let fnc = make_token fnc in
  let (parser, ilp) = expect_token parser LeftParen SyntaxError.error1019 in
  let (parser1, token) = next_token parser in
  let (parser, pts, irp) =
    if (Token.kind token) = RightParen then
      (parser1, (make_missing()), (make_token token))
    else
      let (parser, pts) = parse_type_list parser RightParen in
      let (parser, irp) =
        expect_token parser RightParen SyntaxError.error1011 in
      (parser, pts, irp) in
  let (parser, col) = expect_token parser Colon SyntaxError.error1020 in
  let (parser, ret) = parse_type_specifier parser in
  let (parser, orp) =
    expect_token parser RightParen SyntaxError.error1011 in
  let result = make_closure_type_specifier olp fnc ilp pts irp col ret orp in
  (parser, result)

and parse_tuple_type_specifier parser =

  (* SPEC
      tuple-type-specifier:
        ( type-specifier  ,  type-specifier-list  )
  *)

  let (parser, left_paren) = next_token parser in
  let left_paren = make_token left_paren in
  let (parser, args) = parse_type_list parser RightParen in
  let (parser1, right_paren) = next_token parser in
  if (Token.kind right_paren) = RightParen then
    let result = make_tuple_type_specifier left_paren args
      (make_token right_paren) in
    (parser1, result)
  else
    (* ERROR RECOVERY: Don't eat the token that is in the place of the
       missing ) or ,.  Assume that it is the ) that is missing and
       try to parse whatever is coming after the type.  *)
    let parser = with_error parser SyntaxError.error1022 in
    let result = make_tuple_type_specifier left_paren args (make_missing()) in
    (parser, result)

and parse_nullable_type_specifier parser =
  let (parser, question) = next_token parser in
  let question = make_token question in
  let (parser, nullable_type) = parse_type_specifier parser in
  let result = make_nullable_type_specifier question nullable_type in
  (parser, result)

and parse_classname_type_specifier parser =
  let (parser, token) = next_token parser in
    (* TODO *)
    (parser, make_error [make_token token])

and parse_shape_specifier parser =
  let (parser, token) = next_token parser in
    (* TODO *)
    (parser, make_error [make_token token])
