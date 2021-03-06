open! Import

module Array = Array0
module Bytes = Bytes0

include String0

let invalid_argf = Printf.invalid_argf

let raise_s = Error.raise_s

let stage = Staged.stage

module T = struct
  type t = string [@@deriving_inline hash, sexp]
  let (hash_fold_t :
         Ppx_hash_lib.Std.Hash.state -> t -> Ppx_hash_lib.Std.Hash.state) =
    hash_fold_string

  and (hash : t -> Ppx_hash_lib.Std.Hash.hash_value) =
    let func = hash_string  in fun x  -> func x

  let t_of_sexp : Sexplib.Sexp.t -> t = string_of_sexp
  let sexp_of_t : t -> Sexplib.Sexp.t = sexp_of_string
  [@@@end]
  let compare = compare
end

include T
include Comparator.Make(T)

let equal (t1 : t) t2 = compare t1 t2 = 0

type elt = char

let is_suffix_gen =
  let rec loop s ~suffix ~char_equal idx_suff idx =
    idx_suff < 0
    || ((char_equal suffix.[idx_suff] s.[idx])
        && loop s ~suffix ~char_equal (idx_suff - 1) (idx - 1))
  in
  fun s ~suffix ~char_equal ->
    let len = length s in
    let len_suffix = length suffix in
    len >= len_suffix && loop s ~suffix ~char_equal (len_suffix - 1) (len - 1)
;;

let is_prefix_gen =
  let rec loop s ~prefix ~char_equal i =
    i < 0
    || ((char_equal prefix.[i] s.[i])
        && loop s ~prefix ~char_equal (i - 1))
  in
  fun s ~prefix ~char_equal ->
    let prefix_len = length prefix in
    length s >= prefix_len && loop s ~prefix ~char_equal (prefix_len - 1)
;;

module Caseless = struct
  module T = struct
    type t = string [@@deriving_inline sexp]
    let t_of_sexp : Sexplib.Sexp.t -> t = string_of_sexp
    let sexp_of_t : t -> Sexplib.Sexp.t = sexp_of_string
    [@@@end]

    (* This function gives the same result as [compare (lowercase s1) (lowercase s2)]. It
       is optimised so that it is as fast as that implementation, but uses constant memory
       instead of O(n). It is still an order of magnitude slower than the inbuilt string
       comparison, sadly. *)
    let compare s1 s2 =
      if phys_equal s1 s2
      then 0
      else With_return.with_return (fun r ->
        for i = 0 to min (length s1) (length s2) - 1 do
          match
            Char.compare
              (Char.lowercase (unsafe_get s1 i))
              (Char.lowercase (unsafe_get s2 i))
          with
          | 0 -> ()
          | other -> r.return other
        done;
        (* the Int module is not available here, and [compare] is string comparison *)
        Polymorphic_compare.compare (length s1) (length s2))

    let hash_fold_t state t =
      let len = length t in
      let state = ref (hash_fold_int state len) in
      for pos = 0 to len - 1 do
        state := hash_fold_char !state (Char.lowercase (unsafe_get t pos))
      done;
      !state

    let hash t = Hash.run hash_fold_t t

    let char_equal_caseless c1 c2 = Char.equal (Char.lowercase c1) (Char.lowercase c2)

    let is_suffix s ~suffix = is_suffix_gen s ~suffix ~char_equal:char_equal_caseless
    let is_prefix s ~prefix = is_prefix_gen s ~prefix ~char_equal:char_equal_caseless
  end

  include T
  include Comparable.Make(T)
end

(* This is copied/adapted from 'blit.ml'.
   [sub], [subo] could be implemented using [Blit.Make(Bytes)] plus unsafe casts to/from
   string but were inlined here to avoid using [Bytes.unsafe_of_string] as much as possible.
   Also note that [blit] and [blito] will be deprected and removed in the future.
*)
let sub src ~pos ~len =
  Ordered_collection_common.check_pos_len_exn ~pos ~len ~length:(length src);
  let dst = Bytes.create len in
  if len > 0 then Bytes.unsafe_blit_string ~src ~src_pos:pos ~dst ~dst_pos:0 ~len;
  Bytes.unsafe_to_string ~no_mutation_while_string_reachable:dst
let subo ?(pos = 0) ?len src =
  sub src ~pos ~len:(match len with Some i -> i | None -> length src - pos)

let blit = Bytes.blit_string
let blito ~src ?(src_pos = 0) ?(src_len = length src - src_pos) ~dst ?(dst_pos = 0) () =
  blit ~src ~src_pos ~len:src_len ~dst ~dst_pos

let contains ?pos ?len t char =
  let (pos, len) =
    Ordered_collection_common.get_pos_len_exn ?pos ?len ~length:(length t)
  in
  let last = pos + len in
  let rec loop i = i < last && (Char.equal t.[i] char || loop (i + 1)) in
  loop pos
;;

let is_empty t = length t = 0

let index t char =
  try Some (index_exn t char)
  with Not_found -> None

let rindex t char =
  try Some (rindex_exn t char)
  with Not_found -> None

let index_from t pos char =
  try Some (index_from_exn t pos char)
  with Not_found -> None

let rindex_from t pos char =
  try Some (rindex_from_exn t pos char)
  with Not_found -> None

module Search_pattern = struct

  type t = string * int array [@@deriving_inline sexp_of]
  let sexp_of_t : t -> Sexplib.Sexp.t =
    function
    | (v0,v1) ->
      let v0 = sexp_of_string v0

      and v1 = sexp_of_array sexp_of_int v1
      in Sexplib.Sexp.List [v0; v1]

  [@@@end]

  (* Find max number of matched characters at [next_text_char], given the current
     [matched_chars]. Try to extend the current match, if chars don't match, try to match
     fewer chars. If chars match then extend the match. *)
  let kmp_internal_loop ~matched_chars ~next_text_char ~pattern ~kmp_arr =
    let matched_chars = ref matched_chars in
    while !matched_chars > 0
          && Char.( <> ) next_text_char (unsafe_get pattern !matched_chars) do
      matched_chars := Array.unsafe_get kmp_arr (!matched_chars - 1)
    done;
    if Char.equal next_text_char (unsafe_get pattern !matched_chars) then
      matched_chars := !matched_chars + 1;
    !matched_chars
  ;;

  (* Classic KMP pre-processing of the pattern: build the int array, which, for each i,
     contains the length of the longest non-trivial prefix of s which is equal to a suffix
     ending at s.[i] *)
  let create pattern =
    let n = length pattern in
    let kmp_arr = Array.create ~len:n (-1) in
    if n > 0 then begin
      Array.unsafe_set kmp_arr 0 0;
      let matched_chars = ref 0 in
      for i = 1 to n - 1 do
        matched_chars :=
          kmp_internal_loop
            ~matched_chars:!matched_chars
            ~next_text_char:(unsafe_get pattern i)
            ~pattern
            ~kmp_arr;
        Array.unsafe_set kmp_arr i !matched_chars
      done
    end;
    (pattern, kmp_arr)
  ;;

  (* Classic KMP: use the pre-processed pattern to optimize look-behinds on non-matches.
     We return int to avoid allocation in [index_exn]. -1 means no match. *)
  let index_internal ?(pos=0) (pattern, kmp_arr) ~in_:text =
    if pos < 0 || pos > length text - length pattern then
      -1
    else begin
      let j = ref pos in
      let matched_chars = ref 0 in
      let k = length pattern in
      let n = length text in
      while !j < n && !matched_chars < k do
        let next_text_char = unsafe_get text !j in
        matched_chars :=
          kmp_internal_loop
            ~matched_chars:!matched_chars
            ~next_text_char
            ~pattern
            ~kmp_arr;
        j := !j + 1
      done;
      if !matched_chars = k then
        !j - k
      else
        -1
    end
  ;;

  let index ?pos t ~in_ =
    let p = index_internal ?pos t ~in_ in
    if p < 0 then
      None
    else
      Some p
  ;;

  let index_exn ?pos t ~in_ =
    let p = index_internal ?pos t ~in_ in
    if p >= 0 then
      p
    else
      raise_s (Sexp.message "Substring not found"
                 ["substring", sexp_of_string (fst t)])
  ;;

  let index_all (pattern, kmp_arr) ~may_overlap ~in_:text =
    if length pattern = 0 then
      List.init (1 + length text) ~f:Fn.id
    else begin
      let matched_chars = ref 0 in
      let k = length pattern in
      let n = length text in
      let found = ref [] in
      for j = 0 to n do
        if !matched_chars = k then begin
          found := (j - k)::!found;
          (* we just found a match in the previous iteration *)
          match may_overlap with
          | true -> matched_chars := Array.unsafe_get kmp_arr (k - 1)
          | false -> matched_chars := 0
        end;
        if j < n then begin
          let next_text_char = unsafe_get text j in
          matched_chars :=
            kmp_internal_loop
              ~matched_chars:!matched_chars
              ~next_text_char
              ~pattern
              ~kmp_arr
        end
      done;
      List.rev !found
    end
  ;;

  let replace_first ?pos t ~in_:s ~with_ =
    match index ?pos t ~in_:s with
    | None -> s
    | Some i ->
      let len_s = length s in
      let len_t = length (fst t) in
      let len_with = length with_ in
      let dst = Bytes.create (len_s + len_with - len_t) in
      blit ~src:s ~src_pos:0 ~dst ~dst_pos:0 ~len:i;
      blit ~src:with_ ~src_pos:0 ~dst ~dst_pos:i ~len:len_with;
      blit ~src:s ~src_pos:(i + len_t) ~dst ~dst_pos:(i + len_with) ~len:(len_s - i - len_t);
      Bytes.unsafe_to_string ~no_mutation_while_string_reachable:dst
  ;;


  let replace_all t ~in_:s ~with_ =
    let matches = index_all t ~may_overlap:false ~in_:s in
    match matches with
    | [] -> s
    | _::_ ->
      let len_s = length s in
      let len_t = length (fst t) in
      let len_with = length with_ in
      let num_matches = List.length matches in
      let dst = Bytes.create (len_s + (len_with - len_t) * num_matches) in
      let next_dst_pos = ref 0 in
      let next_src_pos = ref 0 in
      List.iter matches ~f:(fun i ->
        let len = i - !next_src_pos in
        blit ~src:s ~src_pos:!next_src_pos ~dst ~dst_pos:!next_dst_pos ~len;
        blit ~src:with_ ~src_pos:0 ~dst ~dst_pos:(!next_dst_pos + len) ~len:len_with;
        next_dst_pos := !next_dst_pos + len + len_with;
        next_src_pos := !next_src_pos + len + len_t;
      );
      blit ~src:s ~src_pos:!next_src_pos ~dst ~dst_pos:!next_dst_pos
        ~len:(len_s - !next_src_pos);
      Bytes.unsafe_to_string ~no_mutation_while_string_reachable:dst
  ;;
end

let substr_index ?pos t ~pattern =
  Search_pattern.index ?pos (Search_pattern.create pattern) ~in_:t
;;

let substr_index_exn ?pos t ~pattern =
  Search_pattern.index_exn ?pos (Search_pattern.create pattern) ~in_:t
;;

let substr_index_all t ~may_overlap ~pattern =
  Search_pattern.index_all (Search_pattern.create pattern) ~may_overlap ~in_:t
;;

let substr_replace_first ?pos t ~pattern =
  Search_pattern.replace_first ?pos (Search_pattern.create pattern) ~in_:t
;;

let substr_replace_all t ~pattern =
  Search_pattern.replace_all (Search_pattern.create pattern) ~in_:t
;;

let is_substring t ~substring =
  Option.is_some (substr_index t ~pattern:substring)
;;

let id x = x
let of_string = id
let to_string = id

let init n ~f =
  if n < 0 then invalid_argf "String.init %d" n ();
  let t = Bytes.create n in
  for i = 0 to n - 1 do
    Bytes.set t i (f i);
  done;
  Bytes.unsafe_to_string ~no_mutation_while_string_reachable:t
;;

(** See {!Array.normalize} for the following 4 functions. *)
let normalize t i =
  Ordered_collection_common.normalize ~length_fun:length t i
let slice t start stop =
  Ordered_collection_common.slice ~length_fun:length ~sub_fun:sub
    t start stop


let nget x i =
  x.[normalize x i]

let nset x i v =
  Bytes.set x
    (normalize (Bytes.unsafe_to_string ~no_mutation_while_string_reachable:x) i) v

let to_list s =
  let rec loop acc i =
    if i < 0 then
      acc
    else
      loop (s.[i] :: acc) (i-1)
  in
  loop [] (length s - 1)

let to_list_rev s =
  let len = length s in
  let rec loop acc i =
    if i = len then
      acc
    else
      loop (s.[i] :: acc) (i+1)
  in
  loop [] 0

let rev t =
  let len = length t in
  let res = Bytes.create len in
  for i = 0 to len - 1 do
    unsafe_set res i (unsafe_get t (len - 1 - i))
  done;
  Bytes.unsafe_to_string ~no_mutation_while_string_reachable:res
;;

(** Efficient string splitting *)

let lsplit2_exn line ~on:delim =
  let pos = index_exn line delim in
  (sub line ~pos:0 ~len:pos,
   sub line ~pos:(pos+1) ~len:(length line - pos - 1)
  )

let rsplit2_exn line ~on:delim =
  let pos = rindex_exn line delim in
  (sub line ~pos:0 ~len:pos,
   sub line ~pos:(pos+1) ~len:(length line - pos - 1)
  )

let lsplit2 line ~on =
  try Some (lsplit2_exn line ~on) with Not_found -> None

let rsplit2 line ~on =
  try Some (rsplit2_exn line ~on) with Not_found -> None

let rec char_list_mem l (c:char) =
  match l with
  | [] -> false
  | hd::tl -> Char.equal hd c || char_list_mem tl c

let split_gen str ~on =
  let is_delim =
    match on with
    | `char c' -> (fun c -> Char.equal c c')
    | `char_list l -> (fun c -> char_list_mem l c)
  in
  let len = length str in
  let rec loop acc last_pos pos =
    if pos = -1 then
      sub str ~pos:0 ~len:last_pos :: acc
    else
    if is_delim str.[pos] then
      let pos1 = pos + 1 in
      let sub_str = sub str ~pos:pos1 ~len:(last_pos - pos1) in
      loop (sub_str :: acc) pos (pos - 1)
    else loop acc last_pos (pos - 1)
  in
  loop [] len (len - 1)
;;

let split str ~on = split_gen str ~on:(`char on) ;;

let split_on_chars str ~on:chars =
  split_gen str ~on:(`char_list chars)
;;

let split_lines =
  let back_up_at_newline ~t ~pos ~eol =
    pos := !pos - (if !pos > 0 && Char.equal t.[!pos - 1] '\r' then 2 else 1);
    eol := !pos + 1;
  in
  fun t ->
    let n = length t in
    if n = 0
    then []
    else
      (* Invariant: [-1 <= pos < eol]. *)
      let pos = ref (n - 1) in
      let eol = ref n in
      let ac = ref [] in
      (* We treat the end of the string specially, because if the string ends with a
         newline, we don't want an extra empty string at the end of the output. *)
      if Char.equal t.[!pos] '\n' then back_up_at_newline ~t ~pos ~eol;
      while !pos >= 0 do
        if Char.( <> ) t.[!pos] '\n'
        then decr pos
        else
          (* Becuase [pos < eol], we know that [start <= eol]. *)
          let start = !pos + 1 in
          ac := sub t ~pos:start ~len:(!eol - start) :: !ac;
          back_up_at_newline ~t ~pos ~eol
      done;
      sub t ~pos:0 ~len:!eol :: !ac
;;

(* [is_suffix s ~suff] returns [true] if the string [s] ends with the suffix [suff] *)
let is_suffix s ~suffix = is_suffix_gen s ~suffix ~char_equal:Char.equal
let is_prefix s ~prefix = is_prefix_gen s ~prefix ~char_equal:Char.equal

let wrap_sub_n t n ~name ~pos ~len ~on_error =
  if n < 0 then
    invalid_arg (name ^ " expecting nonnegative argument")
  else
    try
      sub t ~pos ~len
    with _ ->
      on_error

let drop_prefix t n = wrap_sub_n ~name:"drop_prefix" t n ~pos:n ~len:(length t - n) ~on_error:""
let drop_suffix t n = wrap_sub_n ~name:"drop_suffix" t n ~pos:0 ~len:(length t - n) ~on_error:""
let prefix t n = wrap_sub_n ~name:"prefix" t n ~pos:0 ~len:n ~on_error:t
let suffix t n = wrap_sub_n ~name:"suffix" t n ~pos:(length t - n) ~len:n ~on_error:t

let lfindi ?(pos=0) t ~f =
  let n = length t in
  let rec loop i =
    if i = n then None
    else if f i t.[i] then Some i
    else loop (i + 1)
  in
  loop pos
;;

let find t ~f =
  match lfindi t ~f:(fun _ c -> f c) with
  | None -> None | Some i -> Some t.[i]

let find_map t ~f =
  let n = length t in
  let rec loop i =
    if i = n then None
    else
      match f t.[i] with
      | None -> loop (i + 1)
      | Some _ as res -> res
  in
  loop 0
;;

let rfindi ?pos t ~f =
  let rec loop i =
    if i < 0 then None
    else begin
      if f i t.[i] then Some i
      else loop (i - 1)
    end
  in
  let pos =
    match pos with
    | Some pos -> pos
    | None -> length t - 1
  in
  loop pos
;;

let last_non_drop ~drop t = rfindi t ~f:(fun _ c -> not (drop c))

let rstrip ?(drop=Char.is_whitespace) t =
  match last_non_drop t ~drop with
  | None -> ""
  | Some i ->
    if i = length t - 1
    then t
    else prefix t (i + 1)
;;

let first_non_drop ~drop t = lfindi t ~f:(fun _ c -> not (drop c))

let lstrip ?(drop=Char.is_whitespace) t =
  match first_non_drop t ~drop with
  | None -> ""
  | Some 0 -> t
  | Some n -> drop_prefix t n
;;

(* [strip t] could be implemented as [lstrip (rstrip t)].  The implementation
   below saves (at least) a factor of two allocation, by only allocating the
   final result.  This also saves some amount of time. *)
let strip ?(drop=Char.is_whitespace) t =
  let length = length t in
  if length = 0 || not (drop t.[0] || drop t.[length - 1])
  then t
  else
    match first_non_drop t ~drop with
    | None -> ""
    | Some first ->
      match last_non_drop t ~drop with
      | None -> assert false
      | Some last -> sub t ~pos:first ~len:(last - first + 1)
;;

let mapi t ~f =
  let l = length t in
  let t' = Bytes.create l in
  for i = 0 to l - 1 do
    Bytes.unsafe_set t' i (f i t.[i])
  done;
  Bytes.unsafe_to_string ~no_mutation_while_string_reachable:t'

(* repeated code to avoid requiring an extra allocation for a closure on each call. *)
let map t ~f =
  let l = length t in
  let t' = Bytes.create l in
  for i = 0 to l - 1 do
    Bytes.unsafe_set t' i (f t.[i])
  done;
  Bytes.unsafe_to_string ~no_mutation_while_string_reachable:t'

let to_array s = Array.init (length s) ~f:(fun i -> s.[i])

let tr ~target ~replacement s =
  map ~f:(fun c -> if Char.equal c target then replacement else c) s
;;

let tr_inplace ~target ~replacement s = (* destructive version of tr *)
  for i = 0 to Bytes.length s - 1 do
    if Char.equal (Bytes.unsafe_get s i) target then Bytes.unsafe_set s i replacement
  done

let exists =
  let rec loop s i ~len ~f = i < len && (f s.[i] || loop s (i + 1) ~len ~f) in
  fun s ~f -> loop s 0 ~len:(length s) ~f
;;

let for_all =
  let rec loop s i ~len ~f = i = len || (f s.[i] && loop s (i + 1) ~len ~f) in
  fun s ~f -> loop s 0 ~len:(length s) ~f
;;

let fold t ~init ~f =
  let n = length t in
  let rec loop i ac = if i = n then ac else loop (i + 1) (f ac t.[i]) in
  loop 0 init
;;

let foldi t ~init ~f =
  let n = length t in
  let rec loop i ac = if i = n then ac else loop (i + 1) (f i ac t.[i]) in
  loop 0 init
;;

let count t ~f = Container.count ~fold t ~f
let sum m t ~f = Container.sum ~fold m t ~f

let min_elt t = Container.min_elt ~fold t
let max_elt t = Container.max_elt ~fold t
let fold_result t ~init ~f = Container.fold_result ~fold ~init ~f t
let fold_until  t ~init ~f = Container.fold_until  ~fold ~init ~f t

let mem =
  let rec loop t c ~pos:i ~len =
    i < len && (Char.equal c (unsafe_get t i) || loop t c ~pos:(i + 1) ~len)
  in
  fun t c ->
    loop t c ~pos:0 ~len:(length t)
;;

(* fast version, if we ever need it:
   {[
     let concat_array ~sep ar =
       let ar_len = Array.length ar in
       if ar_len = 0 then ""
       else
         let sep_len = length sep in
         let res_len_ref = ref (sep_len * (ar_len - 1)) in
         for i = 0 to ar_len - 1 do
           res_len_ref := !res_len_ref + length ar.(i)
         done;
         let res = create !res_len_ref in
         let str_0 = ar.(0) in
         let len_0 = length str_0 in
         blit ~src:str_0 ~src_pos:0 ~dst:res ~dst_pos:0 ~len:len_0;
         let pos_ref = ref len_0 in
         for i = 1 to ar_len - 1 do
           let pos = !pos_ref in
           blit ~src:sep ~src_pos:0 ~dst:res ~dst_pos:pos ~len:sep_len;
           let new_pos = pos + sep_len in
           let str_i = ar.(i) in
           let len_i = length str_i in
           blit ~src:str_i ~src_pos:0 ~dst:res ~dst_pos:new_pos ~len:len_i;
           pos_ref := new_pos + len_i
         done;
         res
   ]} *)

let concat_array ?sep ar = concat ?sep (Array.to_list ar)

let concat_map ?sep s ~f = concat_array ?sep (Array.map (to_array s) ~f)

(* [filter t f] is implemented by the following algorithm.

   Let [n = length t].

   1. Find the lowest [i] such that [not (f t.[i])].

   2. If there is no such [i], then return [t].

   3. If there is such an [i], allocate a string, [out], to hold the result.  [out] has
   length [n - 1], which is the maximum possible output size given that there is at least
   one character not satisfying [f].

   4. Copy characters at indices 0 ... [i - 1] from [t] to [out].

   5. Walk through characters at indices [i+1] ... [n-1] of [t], copying those that
   satisfy [f] from [t] to [out].

   6. If we completely filled [out], then return it.  If not, return the prefix of [out]
   that we did fill in.

   This algorithm has the property that it doesn't allocate a new string if there's
   nothing to filter, which is a common case. *)
let filter t ~f =
  let n = length t in
  let i = ref 0 in
  while !i < n && f t.[!i]; do
    incr i
  done;
  if !i = n then
    t
  else begin
    let out = Bytes.create (n - 1) in
    blit ~src:t ~src_pos:0 ~dst:out ~dst_pos:0 ~len:!i;
    let out_pos = ref !i in
    incr i;
    while !i < n; do
      let c = t.[!i] in
      if f c then (Bytes.set out !out_pos c; incr out_pos);
      incr i
    done;
    let out = Bytes.unsafe_to_string ~no_mutation_while_string_reachable:out in
    if !out_pos = n - 1 then
      out
    else
      sub out ~pos:0 ~len:!out_pos
  end
;;

let chop_prefix s ~prefix =
  if is_prefix s ~prefix then
    Some (drop_prefix s (length prefix))
  else
    None

let chop_prefix_exn s ~prefix =
  match chop_prefix s ~prefix with
  | Some str -> str
  | None ->
    raise (Invalid_argument
             (Printf.sprintf "String.chop_prefix_exn %S %S" s prefix))

let chop_suffix s ~suffix =
  if is_suffix s ~suffix then
    Some (drop_suffix s (length suffix))
  else
    None

let chop_suffix_exn s ~suffix =
  match chop_suffix s ~suffix with
  | Some str -> str
  | None ->
    raise (Invalid_argument
             (Printf.sprintf "String.chop_suffix_exn %S %S" s suffix))

(* There used to be a custom implementation that was faster for very short strings
   (peaking at 40% faster for 4-6 char long strings).
   This new function is around 20% faster than the default hash function, but slower
   than the previous custom implementation. However, the new OCaml function is well
   behaved, and this implementation is less likely to diverge from the default OCaml
   implementation does, which is a desirable property. (The only way to avoid the
   divergence is to expose the macro redefined in hash_stubs.c in the hash.h header of
   the OCaml compiler.) *)
module Hash = struct
  external hash : string -> int = "Base_hash_string" [@@noalloc]
end

(* [include Hash] to make the [external] version override the [hash] from
   [Hashable.Make_binable], so that we get a little bit of a speedup by exposing it as
   external in the mli. *)
let _ = hash
include Hash

include Comparable.Validate (T)

(* for interactive top-levels -- modules deriving from String should have String's pretty
   printer. *)
let pp = Caml.Format.pp_print_string

let of_char c = make 1 c

let of_char_list l =
  let t = Bytes.create (List.length l) in
  List.iteri l ~f:(fun i c -> Bytes.set t i c);
  Bytes.unsafe_to_string ~no_mutation_while_string_reachable:t

module Escaping = struct
  (* If this is changed, make sure to update [escape], which attempts to ensure all the
     invariants checked here.  *)
  let build_and_validate_escapeworthy_map escapeworthy_map escape_char func =
    let escapeworthy_map =
      if List.Assoc.mem escapeworthy_map ~equal:Char.equal escape_char
      then escapeworthy_map
      else (escape_char, escape_char) :: escapeworthy_map
    in
    let arr = Array.create ~len:256 (-1) in
    let rec loop vals = function
      | [] -> Ok arr
      | (c_from, c_to) :: l ->
        let k, v = match func with
          | `Escape -> Char.to_int c_from, c_to
          | `Unescape -> Char.to_int c_to, c_from
        in
        if arr.(k) <> -1 || Set.mem vals v then
          Or_error.error_s
            (Sexp.message "escapeworthy_map not one-to-one"
               [ "c_from", sexp_of_char c_from
               ; "c_to", sexp_of_char c_to
               ; "escapeworthy_map",
                 sexp_of_list (sexp_of_pair sexp_of_char sexp_of_char)
                   escapeworthy_map
               ])
        else (arr.(k) <- Char.to_int v; loop (Set.add vals v) l)
    in
    loop Set.(empty (module Char)) escapeworthy_map
  ;;

  let escape_gen ~escapeworthy_map ~escape_char =
    match
      build_and_validate_escapeworthy_map escapeworthy_map escape_char `Escape
    with
    | Error _ as x -> x
    | Ok escapeworthy ->
      Ok (fun src ->
        (* calculate a list of (index of char to escape * escaped char) first, the order
           is from tail to head *)
        let to_escape_len = ref 0 in
        let to_escape =
          foldi src ~init:[] ~f:(fun i acc c ->
            match escapeworthy.(Char.to_int c) with
            | -1 -> acc
            | n ->
              (* (index of char to escape * escaped char) *)
              incr to_escape_len;
              (i, Char.unsafe_of_int n) :: acc)
        in
        match to_escape with
        | [] -> src
        | _ ->
          (* [to_escape] divide [src] to [List.length to_escape + 1] pieces separated by
             the chars to escape.

             Lets take
             {[
               escape_gen_exn
                 ~escapeworthy_map:[('a', 'A'); ('b', 'B'); ('c', 'C')]
                 ~escape_char:'_'
             ]}
             for example, and assume the string to escape is

             "000a111b222c333"

             then [to_escape] is [(11, 'C'); (7, 'B'); (3, 'A')].

             Then we create a [dst] of length [length src + 3] to store the
             result, copy piece "333" to [dst] directly, then copy '_' and 'C' to [dst];
             then move on to next; after 3 iterations, copy piece "000" and we are done.

             Finally the result will be

             "000_A111_B222_C333" *)
          let src_len = length src in
          let dst_len = src_len + !to_escape_len in
          let dst = Bytes.create dst_len in
          let rec loop last_idx last_dst_pos = function
            | [] ->
              (* copy "000" at last *)
              blit ~src ~src_pos:0 ~dst ~dst_pos:0 ~len:last_idx
            | (idx, escaped_char) :: to_escape -> (*[idx] = the char to escape*)
              (* take first iteration for example *)
              (* calculate length of "333", minus 1 because we don't copy 'c' *)
              let len = last_idx - idx - 1 in
              (* set the dst_pos to copy to *)
              let dst_pos = last_dst_pos - len in
              (* copy "333", set [src_pos] to [idx + 1] to skip 'c' *)
              blit ~src ~src_pos:(idx + 1) ~dst ~dst_pos ~len;
              (* backoff [dst_pos] by 2 to copy '_' and 'C' *)
              let dst_pos = dst_pos - 2 in
              Bytes.set dst dst_pos escape_char;
              Bytes.set dst (dst_pos + 1) escaped_char;
              loop idx dst_pos to_escape
          in
          (* set [last_dst_pos] and [last_idx] to length of [dst] and [src] first *)
          loop src_len dst_len to_escape;
          Bytes.unsafe_to_string ~no_mutation_while_string_reachable:dst
      )
  ;;

  let escape_gen_exn ~escapeworthy_map ~escape_char =
    Or_error.ok_exn (escape_gen ~escapeworthy_map ~escape_char) |> stage
  ;;

  let escape ~escapeworthy ~escape_char =
    (* For [escape_gen_exn], we don't know how to fix invalid escapeworthy_map so we have
       to raise exception; but in this case, we know how to fix duplicated elements in
       escapeworthy list, so we just fix it instead of raising exception to make this
       function easier to use.  *)
    let escapeworthy_map =
      List.map ~f:(fun c -> (c, c))
        (Set.elements (Set.remove (Set.of_list (module Char) escapeworthy) escape_char))
    in
    escape_gen_exn ~escapeworthy_map ~escape_char
  ;;

  (* In an escaped string, any char is either `Escaping, `Escaped or `Literal. For
     example, the escape statuses of chars in string "a_a__" with escape_char = '_' are

     a : `Literal
     _ : `Escaping
     a : `Escaped
     _ : `Escaping
     _ : `Escaped

     [update_escape_status str ~escape_char i previous_status] gets escape status of
     str.[i] basing on escape status of str.[i - 1] *)
  let update_escape_status str ~escape_char i = function
    | `Escaping -> `Escaped
    | `Literal
    | `Escaped -> if Char.equal str.[i] escape_char then `Escaping else `Literal
  ;;

  let unescape_gen ~escapeworthy_map ~escape_char =
    match
      build_and_validate_escapeworthy_map escapeworthy_map escape_char `Unescape
    with
    | Error _ as x -> x
    | Ok escapeworthy ->
      Ok (fun src ->
        (* Continue the example in [escape_gen_exn], now we unescape

           "000_A111_B222_C333"

           back to

           "000a111b222c333"

           Then [to_unescape] is [14; 9; 4], which is indexes of '_'s.

           Then we create a string [dst] to store the result, copy "333" to it, then copy
           'c', then move on to next iteration. After 3 iterations copy "000" and we are
           done.  *)
        (* indexes of escape chars *)
        let to_unescape =
          let rec loop i status acc =
            if i >= length src then acc
            else
              let status = update_escape_status src ~escape_char i status in
              loop (i + 1) status
                (match status with
                 | `Escaping -> i :: acc
                 | `Escaped | `Literal -> acc)
          in
          loop 0 `Literal []
        in
        match to_unescape with
        | [] -> src
        | idx::to_unescape' ->
          let dst = Bytes.create (length src - List.length to_unescape) in
          let rec loop last_idx last_dst_pos = function
            | [] ->
              (* copy "000" at last *)
              blit ~src ~src_pos:0 ~dst ~dst_pos:0 ~len:last_idx
            | idx::to_unescape -> (* [idx] = index of escaping char *)
              (* take 1st iteration as example, calculate the length of "333", minus 2 to
                 skip '_C' *)
              let len = last_idx - idx - 2 in
              (* point [dst_pos] to the position to copy "333" to *)
              let dst_pos = last_dst_pos - len in
              (* copy "333" *)
              blit ~src ~src_pos:(idx + 2) ~dst ~dst_pos ~len;
              (* backoff [dst_pos] by 1 to copy 'c' *)
              let dst_pos = dst_pos - 1 in
              Bytes.set dst dst_pos ( match escapeworthy.(Char.to_int src.[idx + 1]) with
                | -1 -> src.[idx + 1]
                | n -> Char.unsafe_of_int n);
              (* update [last_dst_pos] and [last_idx] *)
              loop idx dst_pos to_unescape
          in
          ( if idx < length src - 1 then
              (* set [last_dst_pos] and [last_idx] to length of [dst] and [src] *)
              loop (length src) (Bytes.length dst) to_unescape
            else
              (* for escaped string ending with an escaping char like "000_", just ignore
                 the last escaping char *)
              loop (length src - 1) (Bytes.length dst) to_unescape'
          );
          Bytes.unsafe_to_string ~no_mutation_while_string_reachable:dst
      )
  ;;

  let unescape_gen_exn ~escapeworthy_map ~escape_char =
    Or_error.ok_exn (unescape_gen ~escapeworthy_map ~escape_char) |> stage
  ;;

  let unescape ~escape_char =
    unescape_gen_exn ~escapeworthy_map:[] ~escape_char

  let preceding_escape_chars str ~escape_char pos =
    let rec loop p cnt =
      if (p < 0) || (Char.( <> ) str.[p] escape_char) then
        cnt
      else
        loop (p - 1) (cnt + 1)
    in
    loop (pos - 1) 0
  ;;

  (* In an escaped string, any char is either `Escaping, `Escaped or `Literal. For
     example, the escape statuses of chars in string "a_a__" with escape_char = '_' are

     a : `Literal
     _ : `Escaping
     a : `Escaped
     _ : `Escaping
     _ : `Escaped

     [update_escape_status str ~escape_char i previous_status] gets escape status of
     str.[i] basing on escape status of str.[i - 1] *)
  let update_escape_status str ~escape_char i = function
    | `Escaping -> `Escaped
    | `Literal
    | `Escaped -> if Char.equal str.[i] escape_char then `Escaping else `Literal
  ;;

  let escape_status str ~escape_char pos =
    let odd = (preceding_escape_chars str ~escape_char pos) mod 2 = 1 in
    match odd, Char.equal str.[pos] escape_char with
    | true, (true|false) -> `Escaped
    | false, true -> `Escaping
    | false, false -> `Literal
  ;;

  let check_bound str pos function_name =
    if pos >= length str || pos < 0 then
      invalid_argf "%s: out of bounds" function_name ()
  ;;

  let is_char_escaping str ~escape_char pos =
    check_bound str pos "is_char_escaping";
    match escape_status str ~escape_char pos with
    | `Escaping -> true
    | `Escaped | `Literal -> false
  ;;

  let is_char_escaped str ~escape_char pos =
    check_bound str pos "is_char_escaped";
    match escape_status str ~escape_char pos with
    | `Escaped -> true
    | `Escaping | `Literal -> false
  ;;

  let is_char_literal str ~escape_char pos =
    check_bound str pos "is_char_literal";
    match escape_status str ~escape_char pos with
    | `Literal -> true
    | `Escaped | `Escaping -> false
  ;;

  let index_from str ~escape_char pos char =
    check_bound str pos "index_from";
    let rec loop i status =
      if i >= pos
      && (match status with `Literal -> true | `Escaped | `Escaping -> false)
      && Char.equal str.[i] char
      then Some i
      else (
        let i = i + 1 in
        if i >= length str then None
        else loop i (update_escape_status str ~escape_char i status))
    in
    loop pos (escape_status str ~escape_char pos)
  ;;

  let index_from_exn str ~escape_char pos char =
    match index_from str ~escape_char pos char with
    | None ->
      raise_s
        (Sexp.message "index_from_exn: not found"
           [ "str"         , sexp_of_t    str
           ; "escape_char" , sexp_of_char escape_char
           ; "pos"         , sexp_of_int  pos
           ; "char"        , sexp_of_char char
           ])
    | Some pos -> pos
  ;;

  let index str ~escape_char char = index_from str ~escape_char 0 char
  let index_exn str ~escape_char char = index_from_exn str ~escape_char 0 char

  let rindex_from str ~escape_char pos char =
    check_bound str pos "rindex_from";
    (* if the target char is the same as [escape_char], we have no way to determine which
       escape_char is literal, so just return None *)
    if Char.equal char escape_char then None
    else
      let rec loop pos =
        if pos < 0 then None
        else (
          let escape_chars = preceding_escape_chars str ~escape_char pos in
          if escape_chars mod 2 = 0 && Char.equal str.[pos] char
          then Some pos else loop (pos - escape_chars - 1))
      in
      loop pos
  ;;

  let rindex_from_exn str ~escape_char pos char =
    match rindex_from str ~escape_char pos char with
    | None ->
      raise_s
        (Sexp.message "rindex_from_exn: not found"
           [ "str"         , sexp_of_t    str
           ; "escape_char" , sexp_of_char escape_char
           ; "pos"         , sexp_of_int  pos
           ; "char"        , sexp_of_char char
           ])
    | Some pos -> pos
  ;;

  let rindex str ~escape_char char =
    if is_empty str
    then None
    else rindex_from str ~escape_char (length str - 1) char
  ;;

  let rindex_exn str ~escape_char char =
    rindex_from_exn str ~escape_char (length str - 1) char
  ;;

  (* [split_gen str ~escape_char ~on] works similarly to [String.split_gen], with an
     additional requirement: only split on literal chars, not escaping or escaped *)
  let split_gen str ~escape_char ~on =
    let is_delim = match on with
      | `char c' -> (fun c -> Char.equal c c')
      | `char_list l -> (fun c -> char_list_mem l c)
    in
    let len = length str in
    let rec loop acc status last_pos pos =
      if pos = len then
        List.rev (sub str ~pos:last_pos ~len:(len - last_pos) :: acc)
      else
        let status = update_escape_status str ~escape_char pos status in
        if (match status with `Literal -> true | `Escaped | `Escaping -> false)
        && is_delim str.[pos]
        then (
          let sub_str = sub str ~pos:last_pos ~len:(pos - last_pos) in
          loop (sub_str :: acc) status (pos + 1) (pos + 1))
        else loop acc status last_pos (pos + 1)
    in
    loop [] `Literal 0 0
  ;;

  let split str ~on = split_gen str ~on:(`char on) ;;

  let split_on_chars str ~on:chars =
    split_gen str ~on:(`char_list chars)
  ;;

  let split_at str pos =
    sub str ~pos:0 ~len:pos,
    sub str ~pos:(pos + 1) ~len:(length str - pos - 1)
  ;;

  let lsplit2 str ~on ~escape_char =
    Option.map (index str ~escape_char on) ~f:(fun x -> split_at str x)
  ;;

  let rsplit2 str ~on ~escape_char =
    Option.map (rindex str ~escape_char on) ~f:(fun x -> split_at str x)
  ;;

  let lsplit2_exn str ~on ~escape_char =
    split_at str (index_exn str ~escape_char on)
  ;;
  let rsplit2_exn str ~on ~escape_char =
    split_at str (rindex_exn str ~escape_char on)
  ;;

  (* [last_non_drop_literal] and [first_non_drop_literal] are either both [None] or both
     [Some]. If [Some], then the former is >= the latter. *)
  let last_non_drop_literal ~drop ~escape_char t =
    rfindi t ~f:(fun i c ->
      not (drop c)
      || is_char_escaping t ~escape_char i
      || is_char_escaped t ~escape_char i)
  let first_non_drop_literal ~drop ~escape_char t =
    lfindi t ~f:(fun i c ->
      not (drop c)
      || is_char_escaping t ~escape_char i
      || is_char_escaped t ~escape_char i)

  let rstrip_literal ?(drop=Char.is_whitespace) t ~escape_char =
    match last_non_drop_literal t ~drop ~escape_char with
    | None -> ""
    | Some i ->
      if i = length t - 1
      then t
      else prefix t (i + 1)
  ;;

  let lstrip_literal ?(drop=Char.is_whitespace) t ~escape_char =
    match first_non_drop_literal t ~drop ~escape_char with
    | None -> ""
    | Some 0 -> t
    | Some n -> drop_prefix t n
  ;;

  (* [strip t] could be implemented as [lstrip (rstrip t)].  The implementation
     below saves (at least) a factor of two allocation, by only allocating the
     final result.  This also saves some amount of time. *)
  let strip_literal ?(drop=Char.is_whitespace) t ~escape_char =
    let length = length t in
    (* performance hack: avoid copying [t] in common cases *)
    if length = 0 || not (drop t.[0] || drop t.[length - 1])
    then t
    else
      match first_non_drop_literal t ~drop ~escape_char with
      | None -> ""
      | Some first ->
        match last_non_drop_literal t ~drop ~escape_char with
        | None -> assert false
        | Some last -> sub t ~pos:first ~len:(last - first + 1)
  ;;
end

module Replace_polymorphic_compare = struct
  let equal = equal
  let compare (x : t) y = compare x y
  let ascending = compare
  let descending x y = compare y x
  let ( >= ) x y = Poly.( >= ) (x : t) y
  let ( <= ) x y = Poly.( <= ) (x : t) y
  let ( =  ) x y = Poly.( =  ) (x : t) y
  let ( >  ) x y = Poly.( >  ) (x : t) y
  let ( <  ) x y = Poly.( <  ) (x : t) y
  let ( <> ) x y = Poly.( <> ) (x : t) y
  let min (x : t) y = if x < y then x else y
  let max (x : t) y = if x > y then x else y
  let between t ~low ~high = low <= t && t <= high
  let clamp_unchecked t ~min ~max =
    if t < min then min else if t <= max then t else max

  let clamp_exn t ~min ~max =
    assert (min <= max);
    clamp_unchecked t ~min ~max

  let clamp t ~min ~max =
    if min > max then
      Or_error.error_s
        (Sexp.message "clamp requires [min <= max]"
           [ "min", T.sexp_of_t min
           ; "max", T.sexp_of_t max
           ])
    else
      Ok (clamp_unchecked t ~min ~max)
end

include Replace_polymorphic_compare
let create = Bytes.create
let fill = Bytes.fill
