open! Import

type 'a t = ('a, Error.t) Result.t [@@deriving_inline compare, hash, sexp]
let compare : 'a . ('a -> 'a -> int) -> 'a t -> 'a t -> int =
  fun _cmp__a  ->
  fun a__001_  ->
  fun b__002_  -> Result.compare _cmp__a Error.compare a__001_ b__002_

let hash_fold_t :
  'a .
    (Ppx_hash_lib.Std.Hash.state -> 'a -> Ppx_hash_lib.Std.Hash.state) ->
  Ppx_hash_lib.Std.Hash.state -> 'a t -> Ppx_hash_lib.Std.Hash.state
  =
  fun _hash_fold_a  ->
  fun hsv  ->
  fun arg  -> Result.hash_fold_t _hash_fold_a Error.hash_fold_t hsv arg

let t_of_sexp : 'a . (Sexplib.Sexp.t -> 'a) -> Sexplib.Sexp.t -> 'a t =
  let _tp_loc = "src/or_error.ml.t"  in
  fun _of_a  -> fun t  -> Result.t_of_sexp _of_a Error.t_of_sexp t
let sexp_of_t : 'a . ('a -> Sexplib.Sexp.t) -> 'a t -> Sexplib.Sexp.t =
  fun _of_a  -> fun v  -> Result.sexp_of_t _of_a Error.sexp_of_t v
[@@@end]

let invariant invariant_a t =
  match t with
  | Ok a -> invariant_a a
  | Error error -> Error.invariant error
;;

include (Result : Monad.S2
         with type ('a, 'b) t := ('a, 'b) Result.t
         with module Let_syntax := Result.Let_syntax)

include Applicative.Make (struct
    type nonrec 'a t = 'a t
    let return = return
    let apply f x =
      Result.combine f x
        ~ok:(fun f x -> f x)
        ~err:(fun e1 e2 -> Error.of_list [e1; e2])
    let map = `Custom map
  end)

module Let_syntax = struct
  let return = return
  include Monad_infix
  module Let_syntax = struct
    let return = return
    let map    = map
    let bind   = bind
    let both   = both (* from Applicative.Make *)
    module Open_on_rhs  = struct end
  end
end

let ok       = Result.ok
let is_ok    = Result.is_ok
let is_error = Result.is_error

let ignore = ignore_m

let try_with ?(backtrace = false) f =
  try Ok (f ())
  with exn -> Error (Error.of_exn exn ?backtrace:(if backtrace then Some `Get else None))
;;

let try_with_join ?backtrace f = join (try_with ?backtrace f)

let ok_exn = function
  | Ok x -> x
  | Error err -> Error.raise err
;;

let of_exn ?backtrace exn = Error (Error.of_exn ?backtrace exn)

let of_exn_result = function
  | Ok _ as z -> z
  | Error exn -> of_exn exn
;;

let error ?strict message a sexp_of_a =
  Error (Error.create ?strict message a sexp_of_a)
;;

let error_s sexp = Error (Error.create_s sexp)

let error_string message = Error (Error.of_string message)

let errorf format = Printf.ksprintf error_string format

let tag t ~tag = Result.map_error t ~f:(Error.tag ~tag)
let tag_arg t message a sexp_of_a =
  Result.map_error t ~f:(fun e -> Error.tag_arg e message a sexp_of_a)
;;

let unimplemented s = error "unimplemented" s sexp_of_string

let combine_errors l = Result.map_error (Result.combine_errors l) ~f:Error.of_list

let combine_errors_unit l = Result.map (combine_errors l) ~f:(fun (_ : unit list) -> ())

let filter_ok_at_least_one l =
  let ok, errs = List.partition_map l ~f:Result.ok_fst in
  match ok with
  | [] -> Error (Error.of_list errs)
  | _ -> Ok ok
;;

let find_ok l =
  match List.find_map l ~f:Result.ok with
  | Some x -> Ok x
  | None ->
    Error (Error.of_list (List.map l ~f:(function
      | Ok _ -> assert false
      | Error err -> err)))
;;

let find_map_ok l ~f =
  With_return.with_return (fun {return} ->
    Error (Error.of_list (List.map l ~f:(fun elt ->
      match f elt with
      | (Ok _ as x) -> return x
      | Error err -> err))))
;;

let map        = Result.map
let iter       = Result.iter
let iter_error = Result.iter_error

module Ok = struct
  let fold t ~init ~f =
    match t with
    | Ok v    -> f init v
    | Error _ -> init
  ;;

  let iter = iter

  module C = Container.Make (struct
      type nonrec 'a t = 'a t
      let fold = fold
      let iter = `Custom iter
    end)

  let count       = C.count
  let exists      = C.exists
  let find        = C.find
  let find_map    = C.find_map
  let fold_result = C.fold_result
  let fold_until  = C.fold_until
  let for_all     = C.for_all
  let is_empty    = is_error
  let length      = C.length
  let max_elt     = C.max_elt
  let min_elt     = C.min_elt
  let mem         = C.mem
  let sum         = C.sum
  let to_array    = C.to_array
  let to_list     = C.to_list
end
