(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2

open Analysis
open Ast
open Statement
open TypeCheck

open Test

module Parallel = Hack_parallel.Std
module TestSetup = AnalysisTestSetup


let parse_source ?(qualifier=[]) source =
  let source =
    let metadata =
      Source.Metadata.create
        ~autogenerated:false
        ~debug:true
        ~declare:false
        ~ignore_lines:[]
        ~strict:false
        ~version:3
        ~number_of_lines:(-1)
        ()
    in
    parse ~qualifier source
    |> (fun source -> { source with Source.metadata })
    |> Preprocessing.preprocess
  in
  source


let check_source source =
  let configuration =
    Configuration.create
      ~debug:true
      ~strict:false
      ~declare:false
      ~infer:false
      ()
  in
  let environment = TestSetup.environment ~configuration () in
  Service.Environment.populate ~configuration environment [source];
  check configuration environment source |> ignore


let assert_call_graph source ~expected =
  let source = parse_source source in
  let configuration =
    Configuration.create ~debug:true ~strict:false ~declare:false ~infer:false ()
  in
  let environment = TestSetup.environment ~configuration () in
  Service.Environment.populate ~configuration environment [source];
  check configuration environment source |> ignore;
  let call_graph = Analysis.CallGraph.of_source environment source in
  let result =
    let fold_call_graph ~key:caller ~data:callees result =
      let callee = List.hd_exn callees in
      Format.sprintf
        "%s -> %s\n%s"
        (Access.show caller)
        (Access.show callee)
        result
    in
    Access.Map.fold call_graph ~init:"" ~f:fold_call_graph
  in
  let expected = expected ^ "\n" in
  assert_equal ~printer:ident result expected


let test_construction _ =
  assert_call_graph
    {|
    class Foo:
      def __init__(self):
        pass

      def bar(self):
        return 10

      def quux(self):
        return self.bar()
    |}
    ~expected:"Foo.quux -> Foo.bar";

  assert_call_graph
    {|
    class Foo:
      def __init__(self):
        pass

      def bar(self):
        return self.quux()

      def quux(self):
        return self.bar()
    |}
    ~expected:
      "Foo.quux -> Foo.bar\n\
       Foo.bar -> Foo.quux"


let test_type_collection _ =
  let open TypeResolutionSharedMemory in
  let (!) = Access.show in
  let assert_type_collection source ~qualifier ~expected =
    let source = parse_source ~qualifier source in
    let configuration =
      Configuration.create
        ~debug:true
        ~strict:false
        ~declare:false
        ~infer:false
        ()
    in
    let environment = TestSetup.environment ~configuration () in
    Service.Environment.populate ~configuration environment [source];
    check configuration environment source |> ignore;
    let defines =
      Preprocessing.defines source
      |> List.map ~f:(fun define -> define.Node.value)
    in
    let Define.{ name; body = statements; _ } = List.nth_exn defines 1 in
    let lookup =
      let build_lookup lookup { key; annotations } =
        Int.Map.set lookup ~key ~data:annotations in
      TypeResolutionSharedMemory.get name
      |> (fun value -> Option.value_exn value)
      |> List.fold ~init:Int.Map.empty ~f:build_lookup
    in
    let test_expect (node_id, statement_index, test_access, expected_type) =
      let key = [%hash: int * int] (node_id, statement_index) in
      let test_access = Access.create test_access in
      let annotations =
        Int.Map.find_exn lookup key
        |> Access.Map.of_alist_exn
      in
      let resolution = Environment.resolution environment ~annotations () in
      let statement = List.nth_exn statements statement_index in
      Visit.collect_accesses_with_location statement
      |> List.hd_exn
      |> fun { Node.value = access; _ } ->
      if String.equal !access !test_access then
        let open Annotated in
        let open Access.Element in
        let last_element =
          Annotated.Access.create access
          |>  Annotated.Access.last_element ~resolution
        in
        match last_element with
        | Signature {
            signature =
              Signature.Found {
                Signature.callable = {
                  Type.Callable.kind = Type.Callable.Named callable_type;
                  _;
                };
                _;
              };
            _;
          } ->
            assert_equal ~printer:ident !callable_type expected_type
        | _ ->
            assert false
    in
    List.iter expected ~f:test_expect

  in
  assert_type_collection
    {|
        class A:
          def foo(self) -> int:
            return 1

        class B:
          def foo(self) -> int:
            return 2

        class X:
          def caller(self):
            a = A()
            a.foo()
            a = B()
            a.foo()
        |}
    ~qualifier:(Access.create "test1")
    ~expected:
      [
        (5, 1, "$local_0$a.foo.(...)", "test1.A.foo");
        (5, 3, "$local_0$a.foo.(...)", "test1.B.foo")
      ];

  assert_type_collection
    {|
       class A:
         def foo(self) -> int:
           return 1

       class B:
         def foo(self) -> A:
           return A()

       class X:
         def caller(self):
           a = B().foo().foo()
    |}
    ~qualifier:(Access.create "test2")
    ~expected:[(5, 0, "$local_0$a.foo.(...).foo.(...)", "test2.A.foo")]



let test_method_overrides _ =
  let (!) = Access.create in
  let assert_method_overrides source ~expected =
    let source = parse_source source in
    let configuration =
      Configuration.create ~debug:true ~strict:false ~declare:false ~infer:false ()
    in
    let environment = TestSetup.environment ~configuration () in
    Service.Environment.populate ~configuration environment [source];
    let overrides_map = Service.Analysis.overrides_of_source environment source in
    let expected_overrides = Access.Map.of_alist_exn expected in
    let equal_elements = List.equal ~equal:Access.equal in
    assert_equal
      ~cmp:(Access.Map.equal equal_elements)
      overrides_map
      expected_overrides
  in
  assert_method_overrides
    {|
      class Foo:
        def foo(): pass
      class Bar(Foo):
        def foo(): pass
      class Baz(Bar):
        def foo(): pass
        def baz(): pass
      class Quux(Foo):
        def foo(): pass
    |}
    ~expected:
      [
        !"Bar.foo", [!"Baz.foo"];
        !"Foo.foo", [!"Bar.foo"; !"Quux.foo"]
      ]


let () =
  Parallel.Daemon.check_entry_point ();
  "callGraph">:::[
    "type_collection">::test_type_collection;
    "build">::test_construction;
    "overrides">::test_method_overrides;
  ]
  |> run_test_tt_main
