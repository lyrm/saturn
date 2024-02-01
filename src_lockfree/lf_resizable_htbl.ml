module Atomic = Transparent_atomic

module Key = struct
  let reverse x =
    (* works for int32 *)
    let x = x land 0xff_ff_ff_ff in
    let x = ((x land 0xaa_aa_aa_aa) lsr 1) lor ((x land 0x55_55_55_55) lsl 1) in
    let x = ((x land 0xcc_cc_cc_cc) lsr 2) lor ((x land 0x33_33_33_33) lsl 2) in
    let x = ((x land 0xf0_f0_f0_f0) lsr 4) lor ((x land 0x0f_0f_0f_0f) lsl 4) in
    let x = ((x land 0xff_00_ff_00) lsr 8) lor ((x land 0x00_ff_00_ff) lsl 8) in
    (x lsr 16) lor (x lsl 16) land 0xffffffff

  (*  let compute_hkey k = reverse k lor 0x00_00_00_01*)

  (** unset most significant turn on bit (for int32) *)
  let unset_msb key =
    let a = key lor (key lsr 1) in
    let a = a lor (a lsr 2) in
    let a = a lor (a lsr 4) in
    let a = a lor (a lsr 8) in
    let a = a lor (a lsr 16) in
    (a lsr 1) land key
end

type ('k, 'v, _) node =
  | Null : ('k, 'v, [> `Null ]) node
  | Node : {
      hashed_key : int; (* hashed and reversed key *)
      content : ('k, 'v) link Atomic.t;
    }
      -> ('k, 'v, [> `Node ]) node
  | Mark : ('k, 'v, [< `Null | `Node ]) node -> ('k, 'v, [> `Mark ]) node

and ('k, 'v, 'n) content = {
  mutable incr : Size.once;
  decr : Size.once;
  bindings : ('k * 'v) list;
      (* collisions are managed by stocking a pair here *)
  next : ('k, 'v, 'n) node;
}

and ('k, 'v) link =
  | Link : ('k, 'v, [< `Null | `Node | `Mark ]) content -> ('k, 'v) link
[@@unboxed]

type ('k, 'v) t = {
  (* how resizing work : only one resizing operations can happen at any given
     time so before triggering a resize operation, a domain need to check this
     flag and change its value from `Ready to `Resizing. That also means that
     the resizing operation per se is not "obstruction-free" (but it does not
     prevent domains from adding or removing values). *)
  flag : [ `Resizing | `Ready ] Atomic.t;
  mask : int Atomic.t;
      (* mutable or  Atomic.t ? Only one domain can change it at any given time *)
  size : Size.t;
  buckets : ('k, 'v) link Atomic.t array Atomic.t;
}

let length t = Size.get t.size
let hash = Fun.id (*Stdlib.Hashtbl.hash*)

(* Can we make it a value instead of a function *)
let dummy_content () =
  { incr = Size.used_once; decr = Size.used_once; bindings = []; next = Null }

exception Marked_bucket

let[@inline] rec find_node size mask bucket key =
  let curr = Atomic.get bucket in
  match curr with
  | Link { next = Mark _; _ } -> raise Marked_bucket
  | _ -> find_node_rec size mask bucket key bucket curr

and find_node_rec size mask bucket key prev curr :
    int
    * _ link Atomic.t
    * (_, _, [< `Null | `Node ]) content
    * (_, _, [< `Null | `Node ]) content =
  match curr with
  | Link { next = Mark _; _ } -> find_node size mask bucket key
  | Link ({ next = Null; _ } as r) -> (-1, prev, r, dummy_content ())
  | Link ({ next = Node node; _ } as curr_node) -> begin
      match Atomic.get node.content with
      | Link { next = Mark next_node; decr; _ } ->
          Size.update_once size decr;
          let after = Link { curr_node with next = next_node } in
          find_node_rec size mask bucket key prev
            (if Atomic.compare_and_set prev curr after then after
             else Atomic.get prev)
      | Link ({ next = Null | Node _; incr; _ } as next_val) ->
          if List.is_empty next_val.bindings then
            Size.update_once size next_val.decr;

          if List.is_empty next_val.bindings && node.hashed_key <= mask then (
            (* this is the situation where a bucket that is not used anymore
               because of a shrinking is seen. It needs to be removed and so
               firstly, marked. *)
            (* could be an issue : what if between the read of  t.mask and
               the next cas operation, the hashtable grows up *)
            let after = Link { next_val with next = Mark next_val.next } in
            Atomic.compare_and_set node.content (Link next_val) after |> ignore;
            find_node_rec size mask bucket key prev curr)
          else begin
            let comp = Int.compare key node.hashed_key in
            if comp == 0 then begin
              if incr != Size.used_once then begin
                Size.update_once size incr;
                next_val.incr <- Size.used_once
              end;
              (comp, prev, curr_node, next_val)
            end
            else begin
              if comp > 0 then
                find_node_rec size mask bucket key node.content (Link next_val)
              else (comp, prev, curr_node, next_val)
            end
          end
    end

let uninit_bucket =
  Obj.repr @@ Atomic.make
  @@ Link
       {
         incr = Size.used_once;
         decr = Size.used_once;
         bindings = [];
         next = Null;
       }
  |> Obj.obj

(* This create function does the whole initialization of bucket *)
let create ~size_exponent : (_, 'v) t =
  let max_size = Int.shift_left 1 size_exponent in
  let mask = Atomic.make (max_size - 1) in
  let size = Size.create () in
  {
    mask;
    flag = Atomic.make `Ready;
    size;
    buckets =
      Atomic.make
      @@ Array.init max_size (fun i ->
             if i = 0 then
               Atomic.make
               @@ Link
                    {
                      incr = Size.used_once;
                      decr = Size.used_once;
                      bindings = [];
                      next = Null;
                    }
             else uninit_bucket);
  }

let rec init_bucket t buckets mask bucket_index =
  let parent_key = Key.unset_msb bucket_index in
  let _, parent_bucket = get_bucket t buckets mask parent_key in
  let rkey = Key.reverse bucket_index in
  let found, prev, curr, _ =
    find_node_rec t.size mask parent_bucket rkey parent_bucket
      (Atomic.get parent_bucket)
  in
  if found == 0 then prev
  else begin
    let decr = Size.used_once in
    let incr = Size.used_once in
    let new_bucket =
      Atomic.make @@ Link { bindings = []; incr; decr; next = curr.next }
    in
    let after =
      (Node { hashed_key = rkey; content = new_bucket }
        : (_, _, [ `Node ]) node)
    in
    if Atomic.compare_and_set prev (Link curr) (Link { curr with next = after })
    then new_bucket
    else init_bucket t buckets mask bucket_index
  end

and get_bucket t buckets mask hkey =
  let bucket_index = hkey land mask in
  let bucket = Array.get buckets bucket_index in
  if bucket == uninit_bucket then begin
    assert (bucket_index <> 0);
    let bucket = init_bucket t buckets mask bucket_index in
    (* An Array.set is alright here because the bucket is either uninitialized or
       as a fixed value (we can not add the corresponding node twice.

       Also, note that when growing we may have a case where some buckets are
       initialized during the copying of t.buckets. Again, this is ok, the
       bucket will end up uninitialized again, but the corresponding node will
       still be in the linked list and it will be quite short to find it
       again.*)
    Array.set buckets bucket_index bucket;
    (bucket_index, bucket)
  end
  else (bucket_index, bucket)

let[@tail_mod_cons] rec replace_bindings key value = function
  | [] -> []
  | (k, v) :: xs as bindings when k == key ->
      if v == value then bindings else (key, value) :: xs
  | x :: xs -> x :: replace_bindings key value xs

let[@inline] rec add_replace op t key hkey v =
  let mask = Atomic.get t.mask in
  let buckets = Atomic.fenceless_get t.buckets in
  let bucket_index, bucket = get_bucket t buckets mask hkey in
  if bucket_index = hkey then
    match Atomic.get bucket with
    | Link { next = Mark _; _ } ->
        assert (not (Atomic.get t.mask == mask));
        add_replace op t key hkey v
    | Link ({ bindings; _ } as before) -> begin
        match bindings with
        | [] ->
            let incr = Size.new_once t.size Size.incr in
            let after = { before with bindings = (key, v) :: []; incr } in
            if Atomic.compare_and_set bucket (Link before) (Link after) then begin
              if after.incr != Size.used_once then begin
                Size.update_once t.size after.incr;
                after.incr <- Size.used_once
              end
            end
            else add_replace op t key hkey v
        | _ ->
            let bindings =
              match op with
              | `Add -> (key, v) :: bindings
              | `Replace -> replace_bindings key v bindings
            in
            if
              not
              @@ Atomic.compare_and_set bucket (Link before)
                   (Link { before with bindings })
            then add_replace op t key hkey v
      end
  else
    try
      add_replace_rec op t.size mask bucket key (Key.reverse hkey) v bucket
        (Atomic.get bucket)
    with Marked_bucket ->
      assert (not (Atomic.get t.mask == mask));
      add_replace op t key hkey v

and add_replace_rec op size mask bucket key rkey v prev curr =
  let found, prev, curr, next = find_node_rec size mask bucket rkey prev curr in
  match (curr.next : (_, _, [ `Node | `Null ]) node) with
  | Node node when found == 0 -> begin
      match next.bindings with
      | [] ->
          assert false
          (*
          let incr = Size.new_once size Size.incr in
          let (Link r as after) =
            Link { next with bindings = (key, v) :: []; incr }
          in
          if Atomic.compare_and_set node.content (Link next) after then begin
            if r.incr != Size.used_once then begin
              Size.update_once size r.incr;
              r.incr <- Size.used_once
            end
          end
          else add_rec size mask bucket key hkey v prev (Atomic.get prev)*)
      | _ ->
          let bindings =
            match op with
            | `Add -> (key, v) :: next.bindings
            | `Replace -> replace_bindings key v next.bindings
          in
          let after = Link { next with bindings } in
          if not @@ Atomic.compare_and_set node.content (Link next) after then
            add_replace_rec op size mask bucket key rkey v bucket
              (Atomic.get bucket)
    end
  | _ -> begin
      let decr = Size.used_once in
      let incr = Size.new_once size Size.incr in
      let (Link r as new_content) =
        Link { bindings = [ (key, v) ]; incr; decr; next = curr.next }
      in
      let after =
        (Node { hashed_key = rkey; content = Atomic.make new_content }
          : (_, _, [ `Node ]) node)
      in
      if
        Atomic.compare_and_set prev (Link curr)
          (Link { curr with next = after })
      then begin
        if r.incr != Size.used_once then begin
          Size.update_once size r.incr;
          r.incr <- Size.used_once
        end
      end
      else
        add_replace_rec op size mask bucket key rkey v bucket
          (Atomic.get bucket)
    end

let add t key v =
  let hkey = hash key in
  add_replace `Add t key hkey v

let replace t key v =
  let hkey = hash key in
  add_replace `Replace t key hkey v

let[@tail_mod_cons] rec remove_first_occ key removed = function
  | (k, _) :: xs when k = key ->
      removed := true;
      xs
  | x :: xs -> x :: remove_first_occ key removed xs
  | [] -> []

let[@inline] rec try_remove t key hkey =
  let mask = Atomic.get t.mask in
  let buckets = Atomic.fenceless_get t.buckets in
  let bucket_index, bucket = get_bucket t buckets mask hkey in
  if bucket_index == hkey then (
    let (Link ({ bindings; _ } as before)) = Atomic.get bucket in

    if before.incr != Size.used_once then begin
      Size.update_once t.size before.incr;
      before.incr <- Size.used_once
    end;

    match bindings with
    | [] -> false
    | (k, _) :: [] ->
        if k != key then false
        else begin
          let decr = Size.new_once t.size Size.decr in
          let after = { before with bindings = []; decr } in
          if Atomic.compare_and_set bucket (Link before) (Link after) then (
            Size.update_once t.size after.decr;
            true)
          else try_remove t key hkey
        end
    | bindings ->
        let removed_bindings = ref false in
        let new_bindings = remove_first_occ key removed_bindings bindings in
        if !removed_bindings then
          let after = { before with bindings = new_bindings } in
          if Atomic.compare_and_set bucket (Link before) (Link after) then (
            Size.update_once t.size after.decr;
            true)
          else try_remove t key hkey
        else false)
  else
    try
      try_remove_rec t.size mask bucket key (Key.reverse hkey) bucket
        (Atomic.get bucket)
    with Marked_bucket ->
      assert (not (Atomic.get t.mask == mask));
      try_remove t key hkey

and try_remove_rec size mask bucket key rkey prev curr =
  let found, prev, curr, next = find_node_rec size mask bucket rkey prev curr in
  match (curr.next : (_, _, [ `Node | `Null ]) node) with
  | Null -> false
  | Node curr_node ->
      if found != 0 then false
      else begin
        match next.bindings with
        | [] ->
            assert false
            (* meeting an empty node is not possible as only buckets can be empty *)
        | (k, _) :: [] ->
            if k != key then false
            else begin
              assert (next.incr = Size.used_once);
              let decr = Size.new_once size Size.decr in
              let after =
                { next with bindings = []; decr; next = Mark next.next }
              in
              if
                Atomic.compare_and_set curr_node.content (Link next)
                  (Link after)
              then (
                find_node_rec size mask bucket rkey prev (Atomic.get prev)
                |> ignore;
                true)
              else
                try_remove_rec size mask bucket key rkey bucket
                  (Atomic.get bucket)
            end
        | bindings -> begin
            let removed_bindinds = ref false in
            let bindings = remove_first_occ key removed_bindinds bindings in
            if !removed_bindinds then begin
              let after = { next with bindings } in
              if
                Atomic.compare_and_set curr_node.content (Link next)
                  (Link after)
              then true
              else
                try_remove_rec size mask bucket key rkey bucket
                  (Atomic.get bucket)
            end
            else false
          end
      end

let try_remove t key =
  let hkey = hash key in
  try_remove t key hkey

let mem t key =
  let hkey = hash key in
  let mask = Atomic.get t.mask in
  let buckets = Atomic.fenceless_get t.buckets in
  let bucket_index, bucket = get_bucket t buckets mask hkey in
  if bucket_index == hkey then (
    let (Link ({ bindings; _ } as before)) = Atomic.get bucket in

    if before.incr != Size.used_once then begin
      Size.update_once t.size before.incr;
      before.incr <- Size.used_once
    end;

    List.mem_assoc key bindings)
  else
    let found, _, _, next = find_node t.size mask bucket (Key.reverse hkey) in
    if found == 0 then List.mem_assoc key next.bindings else false

let find_all t key =
  let hkey = hash key in
  let mask = Atomic.get t.mask in
  let buckets = Atomic.fenceless_get t.buckets in
  let bucket_index, bucket = get_bucket t buckets mask hkey in
  if bucket_index == hkey then (
    let (Link ({ bindings; _ } as before)) = Atomic.get bucket in

    if before.incr != Size.used_once then begin
      Size.update_once t.size before.incr;
      before.incr <- Size.used_once
    end;

    List.fold_right
      (fun (k, v) acc -> if k = key then v :: acc else acc)
      bindings [])
  else
    let found, _, _, next = find_node t.size mask bucket (Key.reverse hkey) in
    if found == 0 then
      List.fold_right
        (fun (k, v) acc -> if k = key then v :: acc else acc)
        next.bindings []
    else []

let find_opt t key =
  let hkey = hash key in
  let mask = Atomic.get t.mask in
  let buckets = Atomic.fenceless_get t.buckets in
  let bucket_index, bucket = get_bucket t buckets mask hkey in
  if bucket_index == hkey then (
    let (Link ({ bindings; _ } as before)) = Atomic.get bucket in

    if before.incr != Size.used_once then begin
      Size.update_once t.size before.incr;
      before.incr <- Size.used_once
    end;

    List.assoc_opt key bindings)
  else
    let found, _, _, next = find_node t.size mask bucket (Key.reverse hkey) in
    if found == 0 then List.assoc_opt key next.bindings else None
