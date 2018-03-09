(*
   Command for pretty-printing S-expressions from the shell.
*)

let rep ic oc =
  let sexp = Sexplib.Sexp.input_sexp ic in
  output_string oc (Sexp_pretty.sexp_to_string sexp);
  flush oc

let rec repl ic oc =
  (try
     rep ic oc
   with End_of_file ->
     exit 0
  );
  repl ic oc

let usage_msg =
  Printf.sprintf "\
Usage: %s
Read an S-expression from stdin and pretty-print it into a human-readable
form to stdout.
"
    Sys.argv.(0)

let options = []

let usage () =
  Arg.usage options usage_msg

let main () =
  let anon_fun s = usage (); exit 1 in
  Arg.parse options anon_fun usage_msg;
  repl stdin stdout

let () = main ()
