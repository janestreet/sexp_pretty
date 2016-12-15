include (Base : (module type of struct include Base end
                  with module Sexp := Base.Sexp))

module Sexp = Sexplib.Sexp

module Out_channel = struct
  type t = Caml.out_channel
end

let ( = ) = Poly.equal

let force = Lazy.force

let of_sexp_error = Base.Not_exposed_properly.Sexp_conv.of_sexp_error
