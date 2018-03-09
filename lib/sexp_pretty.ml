open Base
open Int
open Config
module Sexp = Sexplib.Sexp


module W = Sexp.With_layout

module Format = struct
  include Caml.Format

  let pp_listi sep ?(offset = 0) ?singleton pp fmt list =
    match list with
    | [] -> ()
    | hd::tl ->
      (match singleton, tl with Some pp, [] -> pp offset fmt hd | _ -> pp offset fmt hd);
      List.iteri tl ~f:(fun i el -> Caml.Format.fprintf fmt sep; pp (i+offset+1) fmt el)
  ;;

  let pp_list sep ?singleton pp fmt list =
    let singleton = Option.map singleton ~f:(fun singleton -> (fun _ -> singleton)) in
    pp_listi sep ?singleton (fun _ -> pp) fmt list
  ;;


  [@@@ocaml.warning "-3"]

  let pp_set_tab = Format.pp_set_tab
  let pp_print_tab = Format.pp_print_tab
  let pp_open_tbox = Format.pp_open_tbox
  let pp_close_tbox = Format.pp_close_tbox

end

module Config = Config

type state = {
  is_comment : bool
}

let start_state = {
  is_comment = false;
}

let split = Re_str.regexp "[ \t]+"

let color_to_code = function
  | Black   -> 30
  | Red     -> 31
  | Green   -> 32
  | Yellow  -> 33
  | Blue    -> 34
  | Magenta -> 35
  | Cyan    -> 36
  | White   -> 37
  | Default -> 39

let rainbow_open_tag conf tag =
  let args = Re_str.split split tag in
  let color_count = Array.length conf.color_scheme in
  match args with
  | "d"::n::[] ->
    let i = Int.of_string n in
    "["
    ^Int.to_string
       (color_to_code
          (if i<0 || color_count<1 then Default else conf.color_scheme.(i%color_count))
       )
    ^"m"
  (* Printing out comments. *)
  | "c"::_::[] ->
    (match conf.comments with
     | Print (_,Some clr,_) ->
       "["
       ^Int.to_string (color_to_code clr)
       ^"m"
     | _ -> ""
    )
  | _ -> tag

let rainbow_tags conf =
  { Format.mark_open_tag = rainbow_open_tag conf
  ; Format.mark_close_tag = (fun _-> "[0m")
  ; Format.print_open_tag = ignore
  ; Format.print_close_tag = ignore }

(* Opens n parentheses, starting at level depth. *)
let open_parens conf state ~depth fmt n =
  match conf.paren_coloring,state.is_comment,conf.comments with
  (* Overrides the option not to color parentheses. *)
  | _   , true, Print(_,Some _,_) ->
    for i  = depth to (depth + n - 1) do Format.fprintf fmt "@{<c %d>(@}" i done
  | true, false, _                ->
    for i  = depth to (depth + n - 1) do Format.fprintf fmt "@{<d %d>(@}" i done
  | _   , _    , _                ->
    for _ = depth to (depth + n - 1) do Format.fprintf fmt "(" done

(* Closes n parentheses, starting at level depth+(n-1) to depth. *)
let close_parens conf state ~depth fmt n =
  (* Overrides the option not to color parentheses. *)
  match conf.paren_coloring,state.is_comment,conf.comments with
  | _   , true , Print(_,Some _,_)  ->
    for i  = depth + (n-1) downto depth do Format.fprintf fmt "@{<c %d>)@}" i done
  | true, false, _                  ->
    for i  = depth + (n-1) downto depth do Format.fprintf fmt "@{<d %d>)@}" i done
  | _   , _    , _                  ->
    for _ = depth + (n-1) downto depth do Format.fprintf fmt ")" done

let pp_atom conf state ~depth ~len index fmt at =
  let at =
    if state.is_comment then
      at
    else
      Sexplib.Pre_sexp.mach_maybe_esc_str at
  in
  let should_be_colored =
    match conf.atom_coloring with
    | Color_none            -> false
    | Color_first threshold -> Int.equal index 0 && len<=threshold
    | Color_all             -> true
  in
  if state.is_comment
  then
    match conf.comments with
    | Drop -> assert false
    | Print (_,Some _,_) -> Format.fprintf fmt "@{<c %d>%s@}" depth at
    | Print (_,None  ,_) -> Format.fprintf fmt "%s" at
  else
  if should_be_colored
  then Format.fprintf fmt "@{<d %d>%s@}" depth at
  else Format.fprintf fmt "%s" at

module Normalize = struct
  type t =
    | Sexp of sexp
    | Comment of comment
  and comment =
    | Line_comment of string
    | Block_comment of int * string list
    | Sexp_comment of (comment list) * sexp
  and sexp =
    | Atom of string
    | List of t list

  let parse_sexps = Sexp.With_layout.Parser.sexps Sexp.With_layout.Lexer.main

  module Pos = Sexplib.Src_pos.Relative

  type match_dimension =
    | Horizontal
    | Vertical

  let grab_comments pos =
    let rec grab_comments dimension acc pos = function
      | [] -> acc,[]
      | (W.Sexp _::_) as list -> acc,list
      | (W.Comment (W.Plain_comment (cpos,_)) as comment)::rest ->
        if
          (match dimension with
           | Horizontal -> pos.Pos.row = cpos.Pos.row
           | Vertical   -> pos.Pos.col = cpos.Pos.col)
        then grab_comments Vertical (comment::acc) cpos rest
        else acc,comment::rest
      | (W.Comment (W.Sexp_comment _)::_) as list ->
        acc,list
    in grab_comments Horizontal [] pos

  (* Re-orders comments to have comment that belong to a sexp before it, not after. *)
  let reorder_comments conf t_or_sexp =
    let rec reorder_t_or_sexp = function
      | W.Sexp sexp       -> W.Sexp (reorder_sexp sexp)
      | W.Comment comment -> W.Comment (reorder_comment comment)
    and reorder_sexp = function
      | W.Atom _ as atom      -> atom
      | W.List (pos1,list,pos2) ->
        let list = List.map list ~f:(fun el -> reorder_t_or_sexp el) in
        W.List (pos1,reorder_list list,pos2)
    and reorder_comment = function
      | W.Plain_comment _ as comment        -> comment
      | W.Sexp_comment (pos,comment_list,sexp) ->
        W.Sexp_comment
          (pos,List.map comment_list ~f:(fun el -> reorder_comment el),reorder_sexp sexp)
    and reorder_list  = function
      | [] -> []
      | (W.Sexp (W.Atom (pos,_,_)) as sexp)::rest
      (* Taking the ending position. *)
      | (W.Sexp (W.List (_,_,pos)) as sexp)::rest ->
        let comments,rest = grab_comments pos rest in
        List.rev_append comments (sexp::reorder_list rest)
      | W.Comment _ as comment::rest ->
        comment::reorder_list rest
    in
    if not(conf.sticky_comments)
    then t_or_sexp
    else reorder_t_or_sexp t_or_sexp

  let rec pre_process_atom conf pos atom =
    match conf.atom_printing with
    | Escaped -> `Atom atom
    | Interpreted ->
      Option.value ~default:(`Atom atom) (Option.try_with (fun () ->
        match parse_sexps (Lexing.from_string atom) with
        (* Perhaps normalized the atom, but nothing more to do. *)
        | [W.Sexp (W.Atom (_,_atom_without_spaces,None))] -> `Atom atom
        (* Nested atom, try again. *)
        | [W.Sexp (W.Atom (_,inner_atom,Some _))] -> begin
            match pre_process_atom conf pos inner_atom with
            | `Atom _ -> `Atom atom (* original atom is better since it contains original
                                       spacing which will be stripped off by
                                       pre_process_atom *)
            | `List lst -> `List lst
          end
        (* Parsed one whole sexp, bubble it up. *)
        | [W.Sexp (W.List (_, list, _))] -> `List list
        (* It would cause problems if we parsed a comment in the case the atom is a
           commented out sexp. We will be conservative here and we won't parse the
           comment.
        *)
        | [W.Comment _] -> `Atom atom
        (* Results in an empty. We keep the original. *)
        | [] -> `Atom atom
        (* Parsed a list of multiple sexps. It could either be spliced into the current
           list, or put into a new Sexp list.
           At the moment, they are put into separate lists.
        *)
        (* If needed, we could traverse [sexps] and adjust positions so that they
           corespond to the respective positions in the original file. Also, we could
           calculate the end position of this list correctly.
        *)
        | sexps when
            List.for_all sexps ~f:(function | W.Sexp (W.Atom _) -> true | _ -> false)
          -> (* we parsed a plain string *) `Atom atom
        | sexps ->
          (* If atom was created by failwiths or structural_sexp, it would looks like
             this:
             "human-readable message followed by (potentially (long and (ugly sexp)))"

             We will try to preserve human-readable part by concatenating all sequences
             of top-level atoms into singe atom *)
          let break a b =
            match a, b with
            | W.Sexp (W.Atom _), W.Sexp (W.Atom _) -> false
            | _ -> true
          in
          let concatenate_atoms lst =
            List.group ~break lst
            |> List.map ~f:(function
              | (W.Sexp (W.Atom (pos,_,_))::_) as atoms -> begin
                  let get_atom_contents = function
                    | W.Sexp (W.Atom (_,a,_)) -> a
                    | _ -> assert false (* List.group guarantees that we have only Atoms
                                           here *)
                  in
                  let atom_contents =
                    List.map ~f:get_atom_contents atoms
                    |> String.concat ~sep:" "
                  in
                  let escaped_atom_contents =
                    Sexplib.Pre_sexp.mach_maybe_esc_str atom_contents
                  in
                  [W.Sexp (W.Atom (pos, atom_contents, Some escaped_atom_contents))]
                end
              | (W.Sexp (W.List _)::_) as lists -> lists
              | (W.Comment _::_) as comments -> comments
              | [] -> [] (* cant really happen *)
            )
            |> List.concat
          in
          `List (concatenate_atoms sexps)
      ))
  ;;

  let block_comment = Re_str.regexp "#|\\(\\([\t ]*\\)\\(\\(\n\\|.\\)*\\)\\)|#"

  let line_split = Re_str.regexp "\n[ \t]*"

  let word_split = Re_str.regexp "[ \n\t]+"

  let trailing = Re_str.regexp "\\(.*\\b\\)[ \t]*$"

  let tab_size = 2

  let pre_process_block_comment style comment =
    (* Split along lines or words. *)
    let contents =
      match style with
      | Pretty_print       -> Re_str.split word_split comment
      | Conservative_print -> Re_str.split line_split comment
    in
    (* Remove trailing spaces. *)
    let contents =
      List.map contents
        ~f:(fun line ->
          if Re_str.string_match trailing line 0
          then Re_str.matched_group 1 line
          else line)
    in
    List.filter contents ~f:(fun s -> String.length s > 0)

  let get_size string =
    String.count string ~f:(fun c -> Char.equal c ' ')
    + String.count string ~f:(fun c -> Char.equal c '\t') * tab_size

  exception Drop_exn

  (* Converts to t, does initial pre-processing - interprets/escapes atoms,
     drops/normalizes comments.
  *)
  let rec of_sexp_or_comment conf : W.t_or_comment -> t = function
    | W.Comment comment -> Comment (of_comment conf comment)
    | W.Sexp    sexp    -> Sexp (of_sexp    conf sexp)
  and of_sexp (conf:Config.t) : W.t -> sexp = function
    | W.Atom (pos,atom,_escaped)  ->
      (match pre_process_atom conf pos atom with
       | `Atom atom -> Atom (atom)
       | `List list -> of_sexp_or_comment_list conf list
      )
    | W.List (_,list,_) -> of_sexp_or_comment_list conf list
  and of_sexp_or_comment_list (conf:Config.t) : W.t_or_comment list -> sexp = fun list ->
    let list =
      List.filter_map list
        ~f:(fun el -> try Some (of_sexp_or_comment conf el) with Drop_exn -> None)
    in
    List list
  and of_comment (conf:Config.t) : W.comment -> comment = function
    | W.Plain_comment (_,comment) ->
      (match conf.comments with
       | Drop -> raise Drop_exn
       | Print (indent,_,style) ->
         if Re_str.string_match block_comment comment 0
         then
           let ind =
             match indent with
             | Auto_indent_comment -> get_size (Re_str.matched_group 2 comment) + 2
             | Indent_comment i    -> i
           in
           Block_comment
             (ind,pre_process_block_comment style (Re_str.matched_group 3 comment))
         else Line_comment comment
      )
    | W.Sexp_comment (_,comment_list,sexp) ->
      (match conf.comments with
       | Drop    -> raise Drop_exn
       | Print _ ->
         let comm_list = List.map comment_list ~f:(fun comment -> of_comment conf comment)
         in
         let sexp = of_sexp conf sexp in
         Sexp_comment (comm_list,sexp)
      )
end

module Print = struct
  module N = Normalize

  type forces_breakline = bool

  type opened =
    | Opened
    | Closed

  type 'a tree =
    | Node of 'a tree list
    | Leaf of 'a

  (* Also contains the first atom list. *)
  type shape = (int*string) tree

  type t =
    | Sexp of sexp
    | Comment of comment
  and comment =
    | Line_comment of string
    | Block_comment of int * string list (* Does not contain the #| |#*)
    | Sexp_comment of (comment list * forces_breakline)*sexp
  and sexp =
    | Atom    of string
    (* With leading atoms. *)
    | List    of string list * t_or_aligned list * forces_breakline
    (* Sexp is a tree - List, Aligned, or Singleton *)
    | Singleton of string list * int * sexp * forces_breakline
  and t_or_aligned =
    | Aligned of aligned
    | T of t
  and aligned = shape * line list
  and line =
    | Atom_line of string tree
    | Comment_line of comment

  (* Unwraps singleton lists. *)
  let unwrap sexp =
    let rec inner level = function
      | N.List [N.Sexp (N.List _ as sexp_list)] -> inner (level+1) sexp_list
      | N.List _                 as sexp_list   -> level+1, sexp_list
      | N.Atom _                 as atom        -> level  , atom
    in
    inner 0 sexp

  let maybe_singleton conf (t_list:Normalize.t list) =
    match conf.singleton_limit with
    | Singleton_limit (Atom_threshold max_at,Character_threshold max_char) ->
      let rec maybe_singleton_inner ~atom_count ~char_count acc = function
        | [] -> None
        | N.Sexp (N.Atom atom)::tl ->
          let char_count = char_count + String.length atom in
          if atom_count = max_at || char_count > max_char
          then None
          else maybe_singleton_inner (atom::acc) tl
                 ~atom_count:(atom_count+1) ~char_count:char_count
        | N.Sexp (N.List _ as list)::[] ->
          let level,list = unwrap list in
          Some (List.rev acc,level,list)
        | N.Comment _ :: _ -> None
        | _ -> None
      in maybe_singleton_inner ~atom_count:0 ~char_count:0 [] t_list

  let forces_breakline_sexp = function
    | Atom _ -> false
    | List (_,_,forces) -> forces
    | Singleton (_,_,_,forces) -> forces
  let forces_breakline_comment = function
    | Line_comment _ -> true
    | Block_comment _ -> false
    | Sexp_comment ((_,comm_force),sexp) -> comm_force || forces_breakline_sexp sexp
  let forces_breakline = function
    | Sexp sexp -> forces_breakline_sexp sexp
    | Comment comment -> forces_breakline_comment comment
  let forces_breakline_aligned_or_t = function
    | Aligned _ -> true
    | T t -> forces_breakline t

  exception Cant_align

  (*Check that the shape is the same and returns a new shape with updated sizes of tabs.*)
  let try_check_shape shape =
    let rec try_check_shape_inner shape sexp =
      match shape,sexp with
      | Leaf (len,at),N.Sexp (N.Atom at2) -> Leaf (max len (String.length at2),at),Leaf at2
      | Node shape_list,N.Sexp (N.List sexp_list) ->
        (try
           let (shape_list,atom_list) =
             List.unzip (List.map2_exn shape_list sexp_list ~f:try_check_shape_inner)
           in Node shape_list,Node atom_list
         with | Invalid_argument _ -> raise Cant_align)
      | _,_ -> raise Cant_align
    in
    function
    | N.Comment (N.Line_comment comment) -> Some (shape,Comment_line (Line_comment comment))
    | N.Comment (N.Block_comment (n,list)) -> Some (shape,Comment_line (Block_comment (n,list)))
    | N.Comment (N.Sexp_comment _) -> None
    | N.Sexp _ as sexp ->
      try
        let shape_list,atom_list = try_check_shape_inner shape sexp in
        Some (shape_list,Atom_line atom_list)
      with Cant_align -> None

  let get_shape ~atom_thresh ~char_thresh ~depth_thresh list =
    let rec get_shape_from_list ~depth ~atom_count ~char_count list_acc = function
      | [] -> List.rev list_acc,atom_count,char_count
      | hd::tl ->
        let (shape,atom_count,char_count) =
          get_shape_inner hd
            ~depth:depth ~atom_count:atom_count ~char_count:char_count
        in
        get_shape_from_list (shape::list_acc) tl
          ~depth:depth ~atom_count:atom_count ~char_count:char_count
    and get_shape_inner ~depth ~atom_count ~char_count t =
      (* Breached the depth threshold. *)
      if depth>depth_thresh then raise Cant_align;
      match t with
      | N.Comment _ -> raise Cant_align
      | N.Sexp (N.List list) ->
        let shape_list,atom_count,char_count =
          get_shape_from_list [] list
            ~depth:(depth+1) ~atom_count:atom_count ~char_count:char_count
        in
        Node shape_list,atom_count,char_count
      | N.Sexp (N.Atom atom) ->
        let atom_len = String.length atom in
        let char_count = char_count + atom_len in
        if atom_count<atom_thresh && char_count <= char_thresh
        then (Leaf (atom_len,atom),atom_count+1,char_count)
        (* Breached the number of atoms threshold or the number of characters threshold. *)
        else raise Cant_align
    in
    try
      match get_shape_from_list [] list ~depth:1 ~atom_count:0 ~char_count:0 with
      | shape_list,_,_ -> Some (Node shape_list)
    with Cant_align -> None

  let rec shape_size = function
    | Leaf (len,_) -> len
    | Node list     ->
      List.fold_left list ~init:0 ~f:(fun len shape -> len + shape_size shape)

  let find_alignable shape ~char_thresh list =
    let rec find_alignable shape res_acc = function
      | [] -> shape,List.rev res_acc,[]
      | hd::tl ->
        match try_check_shape shape hd with
        | None -> shape,List.rev res_acc,hd::tl
        | Some (new_shape,res) ->
          if shape_size new_shape <= char_thresh
          then find_alignable new_shape (res::res_acc) tl
          (* Breached the number of characters threshold. *)
          else shape,List.rev res_acc,hd::tl
    in find_alignable shape [] list

  exception Too_many_atoms

  let get_leading_atoms conf (list:Normalize.t list) =
    match conf.leading_threshold with
    | Atom_threshold leading_atom_threshold,Character_threshold leading_char_threshold ->
      let rec get_leading_atoms_inner acc ~atom_count ~char_count = function
        | []                       -> List.rev acc,[]
        | N.Sexp (N.Atom atom)::tl ->
          let char_count = char_count + String.length atom in
          if atom_count=leading_atom_threshold || char_count>leading_char_threshold
          (* Breached the threshold for number of leading atoms. *)
          then raise Too_many_atoms
          else get_leading_atoms_inner (atom::acc) tl
                 ~atom_count:(atom_count+1) ~char_count:char_count
        | list                     -> List.rev acc,list
      in
      try get_leading_atoms_inner [] ~atom_count:0 ~char_count:0 list
      with | Too_many_atoms -> [],list

  let preprocess conf (t:Normalize.t) : t =
    let rec preprocess_t = function
      | N.Comment comment -> Comment (preprocess_comment comment)
      | N.Sexp sexp -> Sexp (preprocess_sexp sexp)
    and preprocess_sexp = function
      | N.Atom atom -> Atom atom
      | N.List list ->
        match maybe_singleton conf list with
        | Some (atoms,lvl,sexp) ->
          let proc_sexp = preprocess_sexp sexp in
          Singleton (atoms,lvl,proc_sexp,forces_breakline_sexp proc_sexp)
        | None ->
          let leading_atoms,rest = get_leading_atoms conf list in
          let aligned_or_t =
            match conf.data_alignment with
            | Data_not_aligned -> List.map rest ~f:(fun el -> T (preprocess_t el))
            | Data_aligned
                (_,
                 Atom_threshold atom_thresh,
                 Character_threshold char_thresh,
                 Depth_threshold depth_thresh)
              -> try_align rest ~atom_thresh:atom_thresh ~char_thresh:char_thresh
                   ~depth_thresh:depth_thresh
          in
          List (leading_atoms,
                aligned_or_t,
                List.exists aligned_or_t ~f:(forces_breakline_aligned_or_t))
    and preprocess_comment = function
      | N.Line_comment comment             -> Line_comment comment
      | N.Block_comment (i,comment)        -> Block_comment (i,comment)
      | N.Sexp_comment (comment_list,sexp) ->
        let proc_comment_list = List.map comment_list ~f:preprocess_comment in
        let proc_sexp = preprocess_sexp sexp in
        let comm_force = List.exists proc_comment_list ~f:forces_breakline_comment in
        Sexp_comment ((proc_comment_list,comm_force),proc_sexp)
    and try_align ~atom_thresh ~char_thresh ~depth_thresh list =
      let rec try_align_inner acc = function
        | [] -> List.rev acc
        | [last] -> List.rev (T (preprocess_t last)::acc)
        | (N.Comment _ as comment)::tl ->
          try_align_inner (T (preprocess_t comment)::acc) tl
        | N.Sexp (N.Atom atom)::tl -> try_align_inner (T (Sexp (Atom atom))::acc) tl
        | N.Sexp (N.List list)::tl ->
          let shape =
            get_shape list ~atom_thresh:atom_thresh ~char_thresh:char_thresh
              ~depth_thresh:depth_thresh
          in
          (match shape with
           | None -> try_align_inner (T (Sexp(preprocess_sexp (N.List list)))::acc) tl
           | Some shape ->
             let shape,aligned,rest = find_alignable shape tl ~char_thresh:char_thresh in
             if List.exists aligned ~f:(function Atom_line _ -> true | _ -> false)
             then try_align_inner (Aligned (shape,aligned)::acc) rest
             else try_align_inner (T (Sexp (preprocess_sexp (N.List list)))::acc) tl
          )
      in try_align_inner [] list
    in preprocess_t t

  let set_up_tabulation
        conf
        state
        parens_aligned
        shape
        depth
        fmt =
    let rec set_up_markers ~depth ~index : shape -> int = function
      | Leaf (tab,at) ->
        Format.pp_set_tab fmt ();
        pp_atom conf state ~depth:depth ~len:1 index fmt at;
        (* Spaces that should still be printed*)
        tab - String.length at
      | Node shape_list ->
        Format.pp_set_tab fmt ();
        open_parens conf state ~depth:(depth+1) fmt 1;
        let trailing_spaces =
          List.foldi shape_list ~init:0
            ~f:(fun i previous_spaces el ->
              for _ = 1 to previous_spaces do Format.fprintf fmt " " done;
              if i>0
              then Format.fprintf fmt " ";
              set_up_markers ~depth:(depth+1) ~index:i el);
        in
        if parens_aligned
        then(
          for _ = 1 to trailing_spaces do Format.fprintf fmt " " done;
          Format.pp_set_tab fmt ();
          close_parens conf state  ~depth:(depth+1) fmt 1;
          0)
        else(
          close_parens conf state  ~depth:(depth+1) fmt 1;
          trailing_spaces)
    in
    ignore (set_up_markers ~depth:depth ~index:0 shape)

  (* The last element forces a breakline. *)
  let last_forces = function
    | List (_,list,true) ->
      (match List.last list with
       | Some (Aligned (_,line_list)) ->(
           match List.last line_list with
           | None -> false
           | Some (Comment_line (Line_comment _)) -> true
           (* For now. *)
           | Some (Atom_line _) -> false
           | _ -> false
         )

       | Some (T (Comment (Line_comment _))) -> true
       | _ -> false)
    | _ -> false

  let rec pp_t conf state ?(opened = Closed) ?(len = 1) depth ?(index = 0) fmt = function
    | Sexp sexp -> pp_sexp conf state ~opened:opened depth ~index:index ~len:len fmt sexp
    | Comment comment -> pp_comment conf state depth ~index:index fmt comment
  and pp_sexp conf state ~opened ?(len = 1) depth ~index fmt = function
    | Atom at -> pp_atom conf state ~depth:depth ~len:len index fmt at
    | List (leading,list,forces_breakline) as sexp_list ->
      let print_leading len fmt leading =
        Format.fprintf fmt "@[<hv>%a@]"
          (Format.pp_listi "@ " (pp_atom conf state ~depth:(depth+1) ~len:len))
          leading
      in
      let print_rest off fmt rest =
        Format.pp_listi "@ "
          (fun i fmt el ->
             pp_t_or_aligned conf state (depth+1) ~index:(i+off) ~len:(List.length rest) fmt el)
          fmt rest
      in
      let print_opened fmt leading rest =
        let leading_len = List.length leading in
        let leading_is_not_empty = leading_len>0 in
        let rest_is_not_empty = not(List.is_empty rest) in
        if leading_is_not_empty
        then print_leading leading_len fmt leading;
        if leading_is_not_empty && rest_is_not_empty
        then Format.pp_print_space fmt ();
        if rest_is_not_empty
        then print_rest leading_len fmt rest
      in
      let print_closed print leading rest =
        let leading_len = List.length leading in
        let leading_not_empty = leading_len>0 in
        let rest_not_empty = not(List.is_empty rest) in
        let same_line_rest =
          Poly.equal conf.opening_parens Same_line
          && rest_not_empty
          && not(leading_not_empty)
        in
        print
          (if same_line_rest
           then 1
           else conf.indent)
          (fun fmt () -> open_parens conf state ~depth:(depth+1) fmt 1) ()
          (fun fmt (leading,rest) ->
             if leading_not_empty
             then print_leading leading_len fmt leading;
             (* Close the leading atom block. *)
             Format.pp_close_box fmt ();
             if rest_not_empty
             then
               if leading_not_empty
               then Format.pp_print_space fmt ()
               else
               if not(same_line_rest)
               then Format.pp_print_cut fmt ();
             if rest_not_empty
             then print_rest leading_len fmt rest)
          (leading,rest)
          (fun fmt () -> close_parens conf state ~depth:(depth+1) fmt 1) ()
      in
      (match leading,list,forces_breakline,opened,
             Poly.equal conf.closing_parens New_line || last_forces sexp_list with
      | [],[],_,Closed,_ ->
        open_parens conf state ~depth:(depth+1) fmt 1;
        close_parens conf state ~depth:(depth+1) fmt 1
      | leading,rest,false,Opened,_ ->
        Format.pp_open_hvbox fmt 0;
        print_opened fmt leading rest;
        Format.pp_close_box fmt ()
      | leading,rest,true,Opened,_ ->
        print_opened fmt leading rest;
      | leading,rest,true,Closed,true ->
        (* There must be something in the list, if it forces a breakline *)
        print_closed (Format.fprintf fmt "@[<v %d>@[<h>%a%a@]@,%a") leading rest
      | leading,rest,true,Closed,false ->
        (* There must be something in the list, if it forces a breakline *)
        print_closed (Format.fprintf fmt "@[<v %d>@[<h>%a%a@]%a") leading rest
      | leading,rest,false,Closed,true ->
        print_closed
          (Format.fprintf fmt "@[<h>@[<hv>@[<hv %d>@[<h>%a%a@]@,@]%a@]") leading rest
      | leading,rest,false,Closed,false ->
        print_closed
          (Format.fprintf fmt "@[<h>@[<hv>@[<hv %d>@[<h>%a%a@]@]%a@]") leading rest
      )
    | Singleton (atoms,d,sexp,forces_breakline) ->
      let print_opened printer atoms =
        printer
          conf.indent
          (Format.pp_listi "@ "
             (pp_atom conf state ~depth:(depth+1) ~len:(List.length atoms))) atoms
          (open_parens conf state ~depth:(depth+2)) d
          (pp_sexp conf state ~opened:Opened (depth+d) ~index:0 ~len:1) sexp
          (close_parens conf state ~depth:(depth+2)) d
      in
      let print_closed printer atoms =
        printer
          conf.indent
          (open_parens conf state ~depth:(depth+1)) 1
          (fun fmt -> function
             | [] -> ()
             | atoms  ->
               Format.pp_listi "@ "
                 (pp_atom conf state ~depth:(depth+1) ~len:(List.length atoms)) fmt atoms;
               Format.pp_print_space fmt ())
          atoms
          (open_parens conf state ~depth:(depth+2)) d
          (pp_sexp conf state ~opened:Opened (depth+d) ~len:1 ~index:0) sexp
          (close_parens conf state ~depth:(depth+1)) (d+1)
      in
      (match atoms,forces_breakline,opened,
             Poly.equal conf.closing_parens New_line || last_forces sexp with
      | [],_,Opened,_ -> assert false
      | atoms,true,Closed,true ->
        print_closed
          (Format.fprintf fmt "@[<v %d>@[<h>%a%a%a@]@,%a@]@,%a")
          atoms
      | atoms,true,Closed,false ->
        print_closed
          (Format.fprintf fmt "@[<v %d>@[<h>%a%a%a@]@,%a@]%a")
          atoms
      | atoms,false,Closed,true ->
        print_closed
          (Format.fprintf fmt "@[<h>@[<hv>@[<hv %d>@[<h>%a%a%a@]@,%a@]@,@]%a@]")
          atoms
      | atoms,false,Closed,false ->
        print_closed
          (Format.fprintf fmt "@[<h>@[<hv>@[<hv %d>@[<h>%a%a%a@]@,%a@]@]%a@]")
          atoms
      | atoms,true,Opened,true ->
        print_opened
          (Format.fprintf fmt "@[<v %d>@[<h>%a@ %a@]@,%a@]@,%a")
          atoms
      | atoms,true,Opened,false ->
        print_opened
          (Format.fprintf fmt "@[<v %d>@[<h>%a@ %a@]@,%a@]%a")
          atoms
      | atoms,false,Opened,true ->
        print_opened
          (Format.fprintf fmt "@[<h>@[<hv>@[<hv %d>@[<h>%a@ %a@]@,%a@]@,@]%a@]")
          atoms
      | atoms,false,Opened,false ->
        print_opened
          (Format.fprintf fmt "@[<h>@[<hv>@[<hv %d>@[<h>%a@ %a@]@,%a@]@]%a@]")
          atoms
      )
  and pp_t_or_aligned conf state depth ~len ~index fmt = function
    | T t -> pp_t conf state ~len:len depth ~index:index fmt t
    | Aligned (shape,line_list) -> pp_aligned conf state depth fmt shape line_list
  and pp_comment conf state depth ~index fmt comment =
    match conf.comments with
    | Drop -> assert false
    | _ -> ();
      match comment with
      | Line_comment comment ->
        pp_atom conf {is_comment = true} ~depth:depth ~len:1 index fmt comment
      | Block_comment (indent,comment_list) ->
        (match conf.comments with
         | Drop -> assert false (* Would have dropped the comment at pre-processing. *)
         | Print (_,Some _,Conservative_print) ->
           Format.fprintf fmt "@{<c %d>@[<h>@[<hv>@[<hv %d>#|%a%a@]@ @]|#@]@}"
         (* This is an ugly hack not to print anything if colors are disabled. The opening
            tag works fine, as it checks whether or not anything should be printed. The
            closing one doesn't (it can't have any arguments, which is bad).
         *)
         | Print (_,None  ,Conservative_print) ->
           Format.fprintf fmt "@{<c %d}@[<h>@[<hv>@[<hv %d>#|%a%a@]@ @]|#@]"
         | Print (_,Some _,Pretty_print) ->
           Format.fprintf fmt "@{<c %d>@[<h>@[<hv>@[<hv %d>#|%a@[<hov>%a@]@]@ @]|#@]@}"
         | Print (_,None  ,Pretty_print) ->
           Format.fprintf fmt "@{<c %d>@[<h>@[<hv>@[<hv %d>#|%a@[<hov>%a@]@]@ @]|#@]"
        )
          depth
          indent
          (fun fmt spaces -> Format.pp_print_break fmt spaces 0)
          (if indent>2 && not(List.is_empty comment_list) then indent-2 else 0)
          (fun fmt comment_list ->
             Format.pp_list "@ "
               (fun fmt comm ->Format.fprintf fmt "%s" comm)
               fmt
               comment_list)
          comment_list
      | Sexp_comment ((comments,_),sexp) ->
        (match conf.comments with
         | Drop -> assert false
         | Print (_,Some _,_) ->
           Format.fprintf fmt "@{<c %d>#;@}@ " depth
         | Print (_,None  ,_) ->
           Format.fprintf fmt "#;@ ");
        List.iteri
          comments
          ~f:(fun i comm -> pp_comment conf state depth ~index:i fmt comm);
        if not(List.is_empty comments)
        then Format.pp_print_space fmt ();
        pp_sexp conf {is_comment = true} ~opened:Closed depth ~index:index fmt sexp
  and pp_aligned conf state depth fmt shape align_list =
    let parens_aligned =         (match conf.data_alignment with
      | Data_aligned (Parens_alignment a,_,_,_) -> a
      | _ -> assert false)
    in
    let rec print_aligned ~depth index = function
      | Leaf at ->
        Format.pp_print_tab fmt ();
        pp_atom conf state ~depth:depth ~len:1 index fmt at
      | Node list ->
        Format.pp_print_tab fmt ();
        open_parens conf state ~depth:(depth+1) fmt 1;
        List.iteri list ~f:(print_aligned ~depth:(depth+1));
        if parens_aligned
        then Format.pp_print_tab fmt ();
        close_parens conf state ~depth:(depth+1) fmt 1
    in
    let print_aligned_or_comment index = function
      (* Comments on a separate line for now. *)
      | Comment_line comm ->
        Format.pp_print_cut fmt ();
        pp_comment conf state depth ~index:index fmt comm
      | Atom_line line ->
        Format.pp_print_cut fmt ();
        print_aligned ~depth:depth 0 line
    in
    Format.pp_open_tbox fmt ();
    set_up_tabulation conf state parens_aligned shape depth fmt;
    List.iteri align_list ~f:print_aligned_or_comment;
    Format.pp_close_tbox fmt ()

  let pp_sexp_rainbow_toplevel conf fmt sexp =
    let sexp = Normalize.reorder_comments conf sexp in
    let t = Normalize.of_sexp_or_comment conf sexp in
    let aligned = preprocess conf t in
    Format.fprintf fmt "@[<v>%a@]@."
      (pp_t conf start_state ~opened:Closed (0) ~index:0) aligned
end

let setup conf fmt =
  Format.pp_set_formatter_tag_functions fmt (rainbow_tags conf);
  Format.pp_set_tags fmt true

let run ~next conf fmt =
  setup conf fmt;
  let rec loop prints_newline =
    match next () with
    | None -> ()
    | Some t_or_comment ->
      match conf.comments, t_or_comment with
      | Drop     , W.Comment _ -> loop prints_newline
      | Print _  , W.Comment _ ->
        if prints_newline && Poly.equal conf.separator Empty_line
        then Format.pp_print_break fmt 0 0;
        Print.pp_sexp_rainbow_toplevel conf fmt t_or_comment;
        loop false
      | _        , W.Sexp    _ ->
        if prints_newline && Poly.equal conf.separator Empty_line
        then Format.pp_print_break fmt 0 0;
        Print.pp_sexp_rainbow_toplevel conf fmt t_or_comment;
        loop true
  in
  Format.pp_open_vbox fmt 0;
  loop false;
  Format.pp_close_box fmt ();
  Format.pp_print_flush fmt ();
;;

let dummy_pos =
  { Sexplib.Src_pos.Relative.row = 0
  ; col = 0
  }

let rec sexp_to_sexp_or_comment = function
  | Sexp.Atom at   ->
    let fmt_at = Some (Sexplib.Pre_sexp.mach_maybe_esc_str at) in
    W.Sexp (W.Atom (dummy_pos,at,fmt_at))
  | Sexp.List list ->
    W.Sexp (W.List (dummy_pos,List.map list ~f:sexp_to_sexp_or_comment,dummy_pos))


module type S = sig
  type sexp

  type 'a writer = Config.t -> 'a -> sexp -> unit

  val pp_formatter   : Format.formatter        writer
  val pp_formatter'  : next:(unit -> sexp option) -> Config.t -> Caml.Format.formatter -> unit
  val pp_buffer      : Buffer.t                writer
  val pp_out_channel : Caml.out_channel        writer
  val pp_blit        : (string, unit) Blit.sub writer

  val pretty_string : Config.t -> sexp -> string

  val sexp_to_string : sexp -> string
end

module Make (M : sig
    type t
    val to_sexp_or_comment : t -> Sexp.With_layout.t_or_comment
  end) : S with type sexp := M.t = struct

  type 'a writer = Config.t -> 'a -> M.t -> unit

  let pp_formatter conf fmt sexp =
    let t_or_comment = M.to_sexp_or_comment sexp in
    let next =
      let stop = ref false in
      (fun () -> if !stop then None else (stop := true; Some t_or_comment))
    in
    run ~next conf fmt
  ;;

  let pp_formatter' ~next conf fmt =
    run ~next:(fun () ->
      match next () with
      | None -> None
      | Some s -> Some (M.to_sexp_or_comment s))
      conf fmt

  let pp_buffer conf buffer sexp =
    pp_formatter conf (Format.formatter_of_buffer buffer) sexp
  ;;

  let pp_out_channel conf oc sexp =
    pp_formatter conf (Format.formatter_of_out_channel oc) sexp
  ;;

  let pp_blit conf blit sexp =
    let formatter = Format.make_formatter (fun buf pos len -> blit buf ~pos ~len) ignore in
    pp_formatter conf formatter sexp
  ;;

  let pretty_string conf sexp =
    let buffer = Buffer.create 16 in
    pp_buffer conf buffer sexp;
    Buffer.contents buffer
  ;;

  let sexp_to_string =
    let config = lazy (Config.create ~color:false ()) in
    fun sexp -> pretty_string (Lazy.force config) sexp
  ;;
end

include Make (struct
    type t = Sexp.t
    let to_sexp_or_comment = sexp_to_sexp_or_comment
  end)

module Sexp_with_layout = Make (struct
    type t = W.t_or_comment
    let to_sexp_or_comment = Fn.id
  end)
