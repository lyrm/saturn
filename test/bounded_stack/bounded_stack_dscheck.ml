module Stack = Bounded_stack

let drain stack = Stack.pop_all stack |> List.length

let push_pop () =
  Atomic.trace (fun () ->
      let stack = Stack.create () in
      let items_total = 4 in

      (* producer *)
      Atomic.spawn (fun () ->
          for i = 1 to items_total do
            Stack.try_push stack i |> ignore
          done);

      (* consumer *)
      let popped = ref [] in
      Atomic.spawn (fun () ->
          for _ = 1 to items_total do
            match Stack.pop_opt stack with
            | None -> ()
            | Some v -> popped := v :: !popped
          done);

      (* checks*)
      Atomic.final (fun () ->
          Atomic.check (fun () ->
              let remaining = Stack.pop_all stack in
              let pushed = List.init items_total (fun x -> x + 1) in
              List.sort Int.compare (!popped @ remaining) = pushed)))

let push_drop () =
  Atomic.trace (fun () ->
      let stack = Stack.create () in
      let items_total = 4 in

      (* producer *)
      Atomic.spawn (fun () ->
          for i = 1 to items_total do
            Stack.try_push stack i |> ignore
          done);

      (* consumer *)
      let dropped = ref 0 in
      Atomic.spawn (fun () ->
          for _ = 1 to items_total do
            match Stack.drop_exn stack with
            | () -> dropped := !dropped + 1
            | exception Stack.Empty -> ()
          done);

      (* checks*)
      Atomic.final (fun () ->
          Atomic.check (fun () ->
              let remaining = drain stack in
              !dropped + remaining = items_total)))

let push_pop_with_capacity () =
  Atomic.trace (fun () ->
      let stack = Stack.create ~capacity:2 () in
      let items_total = 4 in

      (* producer *)
      let pushed = Array.make items_total false in
      Atomic.spawn (fun () ->
          Array.iteri (fun i _ -> pushed.(i) <- Stack.try_push stack i) pushed);

      (* consumer *)
      let popped = Array.make items_total None in
      Atomic.spawn (fun () ->
          Array.iteri (fun i _ -> popped.(i) <- Stack.pop_opt stack) popped);
      (* checks*)
      Atomic.final (fun () ->
          let popped = Array.to_list popped |> List.filter_map Fun.id in
          let remaining = Stack.pop_all stack in
          Atomic.check (fun () ->
              let xor a b = (a && not b) || ((not a) && b) in
              try
                Array.iteri
                  (fun i elt ->
                    if elt then begin
                      if not @@ xor (List.mem i remaining) (List.mem i popped)
                      then raise Exit
                    end
                    else if List.mem i remaining || List.mem i popped then
                      raise Exit)
                  pushed;
                true
              with _ -> false)))

let push_push () =
  Atomic.trace (fun () ->
      let stack = Stack.create () in
      let items_total = 6 in

      (* two producers *)
      for i = 0 to 1 do
        Atomic.spawn (fun () ->
            for j = 1 to items_total / 2 do
              (* even nums belong to thr 1, odd nums to thr 2 *)
              Stack.try_push stack (i + (j * 2)) |> ignore
            done)
      done;

      (* checks*)
      Atomic.final (fun () ->
          let items = Stack.pop_all stack in

          (* got the same number of items out as in *)
          Atomic.check (fun () -> items_total = List.length items);

          (* they are in lifo order *)
          let odd, even = List.partition (fun v -> v mod 2 == 0) items in

          Atomic.check (fun () -> List.sort Int.compare odd = List.rev odd);
          Atomic.check (fun () -> List.sort Int.compare even = List.rev even)))

let push_push_with_capacity () =
  Atomic.trace (fun () ->
      let capacity = 3 in
      let stack = Stack.create ~capacity () in
      let items_total = 6 in

      (* two producers *)
      for i = 0 to 1 do
        Atomic.spawn (fun () ->
            for j = 1 to items_total / 2 do
              (* even nums belong to thr 1, odd nums to thr 2 *)
              Stack.try_push stack (i + (j * 2)) |> ignore
            done)
      done;

      (* checks*)
      Atomic.final (fun () ->
          let items = Stack.pop_all stack in

          (* got the same number of items out as in *)
          Atomic.check (fun () -> capacity = List.length items)))

let pop_pop () =
  Atomic.trace (fun () ->
      let items_total = 4 in

      let pushed = List.init items_total (fun x -> x + 1) in
      let stack = Stack.of_list_exn pushed in

      (* two consumers *)
      let lists = [ ref []; ref [] ] in
      List.iter
        (fun list ->
          Atomic.spawn (fun () ->
              for _ = 1 to items_total / 2 do
                (* even nums belong to thr 1, odd nums to thr 2 *)
                list := Option.get (Stack.pop_opt stack) :: !list
              done)
          |> ignore)
        lists;

      (* checks*)
      Atomic.final (fun () ->
          let l1 = !(List.nth lists 0) in
          let l2 = !(List.nth lists 1) in

          (* got the same number of items out as in *)
          Atomic.check (fun () -> items_total = List.length l1 + List.length l2);

          (* they are in lifo order *)
          Atomic.check (fun () -> List.sort Int.compare l1 = l1);
          Atomic.check (fun () -> List.sort Int.compare l2 = l2)))

let pop_push_all () =
  Atomic.trace (fun () ->
      let stack = Stack.create () in
      let n_items = 4 in
      let items = List.init n_items (fun x -> x + 1) in

      Atomic.spawn (fun () -> Stack.try_push_all stack items |> ignore);

      let popped = ref [] in
      Atomic.spawn (fun () ->
          for _ = 1 to n_items do
            popped := Stack.pop_opt stack :: !popped
          done);

      Atomic.final (fun () ->
          let popped =
            List.filter Option.is_some !popped |> List.map Option.get
          in
          (* got the same number of items out as in *)
          Atomic.check (fun () ->
              popped
              = List.filteri
                  (fun i _ -> i >= n_items - List.length popped)
                  items)))

let two_domains () =
  Atomic.trace (fun () ->
      let stack = Stack.create () in
      let n1, n2 = (1, 2) in

      (* two producers *)
      let lists =
        [
          (List.init n1 (fun i -> i), ref []);
          (List.init n2 (fun i -> i + n1), ref []);
        ]
      in
      List.iter
        (fun (lpush, lpop) ->
          Atomic.spawn (fun () ->
              List.iter
                (fun elt ->
                  (* even nums belong to thr 1, odd nums to thr 2 *)
                  Stack.try_push stack elt |> ignore;
                  lpop := Option.get (Stack.pop_opt stack) :: !lpop)
                lpush)
          |> ignore)
        lists;

      (* checks*)
      Atomic.final (fun () ->
          let lpop1 = !(List.nth lists 0 |> snd) in
          let lpop2 = !(List.nth lists 1 |> snd) in

          (* got the same number of items out as in *)
          Atomic.check (fun () -> List.length lpop1 = 1);
          Atomic.check (fun () -> List.length lpop2 = 2);

          (* no element are missing *)
          Atomic.check (fun () ->
              List.sort Int.compare (lpop1 @ lpop2)
              = List.init (n1 + n2) (fun i -> i))))

let two_domains_more_pop () =
  Atomic.trace (fun () ->
      let stack = Stack.create () in
      let n1, n2 = (2, 1) in

      (* two producers *)
      let lists =
        [
          (List.init n1 (fun i -> i), ref []);
          (List.init n2 (fun i -> i + n1), ref []);
        ]
      in
      List.iter
        (fun (lpush, lpop) ->
          Atomic.spawn (fun () ->
              List.iter
                (fun elt ->
                  Stack.try_push stack elt |> ignore;
                  lpop := Stack.pop_opt stack :: !lpop;
                  lpop := Stack.pop_opt stack :: !lpop)
                lpush)
          |> ignore)
        lists;

      (* checks*)
      Atomic.final (fun () ->
          let lpop1 =
            !(List.nth lists 0 |> snd)
            |> List.filter Option.is_some |> List.map Option.get
          in
          let lpop2 =
            !(List.nth lists 1 |> snd)
            |> List.filter Option.is_some |> List.map Option.get
          in

          (* got the same number of items out as in *)
          Atomic.check (fun () ->
              n1 + n2 = List.length lpop1 + List.length lpop2);

          (* no element are missing *)
          Atomic.check (fun () ->
              List.sort Int.compare (lpop1 @ lpop2)
              = List.init (n1 + n2) (fun i -> i))))

let pop_all () =
  Atomic.trace (fun () ->
      let stack = Stack.create () in
      let n_items = 6 in
      Atomic.spawn (fun () ->
          for i = 0 to n_items - 1 do
            Stack.try_push stack i |> ignore
          done);

      let popped = ref [] in
      Atomic.spawn (fun () -> popped := Stack.pop_all stack);

      Atomic.final (fun () ->
          let remaining = Stack.pop_all stack in

          (* got the same number of items out as in *)
          Atomic.check (fun () ->
              remaining @ !popped = List.rev @@ List.init n_items Fun.id)))

let () =
  let open Alcotest in
  run "Stack_dscheck"
    [
      ( "basic",
        [
          test_case "1-producer-1-consumer" `Slow push_pop;
          test_case "1-producer-1-consumer-capacity" `Slow
            push_pop_with_capacity;
          test_case "1-push-1-drop" `Slow push_drop;
          test_case "2-producers" `Slow push_push;
          test_case "2-producers-capacity" `Slow push_push_with_capacity;
          test_case "2-consumers" `Slow pop_pop;
          test_case "2-domains" `Slow two_domains;
          test_case "2-domains-more-pops" `Slow two_domains_more_pop;
          test_case "2-domains-pops_all" `Slow pop_all;
          test_case "1-pop-1-push-all" `Slow pop_push_all;
        ] );
    ]
