open Biocaml_internal_pervasives

(*
  Version 2:
  http://www.sanger.ac.uk/resources/software/gff/spec.html
  http://gmod.org/wiki/GFF2
  
  Version 3:
  http://www.sequenceontology.org/gff3.shtml
  http://gmod.org/wiki/GFF3
*)

type t = {
  seqname: string;
  source: string option;
  feature: string option;
  pos: int * int;

  score: float option;
  strand: [`plus | `minus | `not_applicable | `unknown ];
  phase: int option;
  attributes: (string * string list) list;
}

type stream_item = [ `comment of string | `record of t ]

type parse_error = 
[ `cannot_parse_float of Biocaml_pos.t * string
| `cannot_parse_int of Biocaml_pos.t * string
| `cannot_parse_strand of Biocaml_pos.t * string
| `cannot_parse_string of Biocaml_pos.t * string
| `empty_line of Biocaml_pos.t
| `incomplete_input of
    Biocaml_pos.t * string list * string option
| `wrong_attributes of Biocaml_pos.t * string
| `wrong_row of Biocaml_pos.t * string
| `wrong_url_escaping of Biocaml_pos.t * string ]

open Result

let url_escape s =
  let b = Buffer.create (String.length s) in
  String.iter s (function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' as c -> Buffer.add_char b c
  | anyother -> Buffer.add_string b (sprintf "%%%02X" (Char.to_int anyother)));
  Buffer.contents b

let url_unescape pos s =
  let buf = Buffer.create (String.length s) in
  let rec loop pos = 
    match String.lfindi s ~pos ~f:(fun _ c -> (=) '%' c) with
    | None ->
      Buffer.add_substring buf s pos String.(length s - pos)
    | Some idx ->
      if String.length s >= idx + 2 then (
        let char = Scanf.sscanf (String.sub s (idx + 1) 2) "%x" ident in
        Buffer.add_substring buf s pos String.(idx - pos);
        Buffer.add_char buf (Char.of_int_exn char);
        loop (idx + 3)
      ) else (
        failwith "A"
      )
  in
  try loop 0; Ok (Buffer.contents buf) with
  | e -> Error (`wrong_url_escaping (pos, s))
  
let parse_string msg pos i =
  begin try Ok (Scanf.sscanf i "%S " ident) with
  | e ->
    begin match (Scanf.sscanf i "%s " ident) with
    | "" -> Error (`cannot_parse_string (pos, msg))
    | s -> url_unescape pos s
    end
  end
let parse_string_opt m pos i =
  parse_string m pos i >>= fun s ->
  begin match s with
  | "." -> return None
  | s -> return (Some s)
  end

let parse_int msg pos i =
  parse_string msg pos i >>= fun s ->
  (try return (Int.of_string s)
   with e -> fail (`cannot_parse_int (pos, msg)))
    
let parse_float_opt msg pos i =
  parse_string_opt msg pos i >>= function
  | Some s ->
    (try return (Some (Float.of_string s))
     with e -> fail (`cannot_parse_float (pos, msg)))
  | None -> return None
  
let parse_int_opt msg pos i =
  parse_string_opt msg pos i >>= function
  | Some s ->
    (try return (Some (Int.of_string s))
     with e -> fail (`cannot_parse_int (pos, msg)))
  | None -> return None
    
let parse_attributes_version_3 position i =
  let whole_thing = String.concat ~sep:"\t" i in
  (*   let b = Buffer.create 42 in *)
  (*   String.iter (String.concat ~sep:"\t" i) (function *)
  (*   | ' ' -> Buffer.add_string b "%20" *)
  (*   | c -> Buffer.add_char b c); *)
  (*   Buffer.contents b *)
  (* in *)
  let get_csv s =
    List.map (String.split ~on:',' s)
      (fun s -> parse_string "value" position String.(strip s))
    |! List.partition_map ~f:Result.ok_fst
    |! (function
      | (ok, []) -> return ok
      | (_, notok :: _) -> fail notok) in
  let rec loop pos acc =
    begin match String.lfindi whole_thing ~pos ~f:(fun _ c -> c = '=') with
    | Some equal ->
      parse_string "tag" position (String.slice whole_thing pos equal)
      >>= fun tag ->
      let pos = equal + 1 in
      begin match String.lfindi whole_thing ~pos ~f:(fun _ c -> c = ';') with
      | Some semicolon ->
        let delimited = String.slice whole_thing pos semicolon in
        get_csv delimited
        >>= fun values ->
        loop (semicolon + 1) ((tag, values) :: acc)
      | None ->
        let delimited = String.(sub whole_thing pos (length whole_thing - pos)) in
        get_csv delimited
        >>= fun values ->
        return ((tag, values) :: acc)
      end
    | None ->
      if pos >= String.length whole_thing then
        return acc
      else
        fail (`wrong_attributes (position, whole_thing))
    end
  in
  (try loop 0 [] with e -> fail (`wrong_attributes (position, whole_thing)))
  >>| List.rev

let parse_attributes_version_2 position l =
  let whole_thing = String.(concat ~sep:"\t" l |! strip) in
  let parse_string i =
    begin try Some (Scanf.bscanf i "%S " ident) with
    | e ->
      begin match (Scanf.bscanf i "%s " ident) with
      | "" -> None
      | s -> Some s
      end
    end
  in
  let inch = Scanf.Scanning.from_string whole_thing in
  let tokens = Stream.(from (fun _ -> parse_string inch) |! npeek max_int) in
  let rec go_3_by_3 acc = function
    | k  :: v :: ";" :: rest -> go_3_by_3 ((k, [v]) :: acc) rest
    | [] | [";"] -> return (List.rev acc)
    | problem -> fail (`wrong_attributes (position, whole_thing))
  in
  go_3_by_3 [] tokens

  
let parse_row ~version pos s =
  let output_result = function  Ok o -> `output o | Error e -> `error e in
  let fields = String.split ~on:'\t' s in
  begin match fields with
  | seqname :: source :: feature :: start :: stop :: score :: strand :: phase
    :: rest ->
    let result =
      parse_string "Sequence name" pos seqname >>= fun seqname ->
      parse_string_opt "Source" pos source >>= fun source ->
      parse_string_opt "Feature" pos feature >>= fun feature ->
      parse_int "Start Position" pos start >>= fun start ->
      parse_int "Stop Position" pos stop >>= fun stop ->
      parse_float_opt "Score" pos score >>= fun score ->
      parse_string_opt "Strand" pos strand
      >>= (function
      | Some "+" -> return `plus
      | None -> return `not_applicable
      | Some "-" -> return `minus
      | Some "?" -> return `unknown
      | Some s -> fail (`cannot_parse_strand (pos, s)))
      >>= fun strand ->
      parse_int_opt "Phase/Frame" pos phase >>= fun phase ->
      begin match version with
      | `two -> parse_attributes_version_2 pos rest
      | `three -> parse_attributes_version_3 pos rest
      end
      >>= fun attributes ->
      return (`record {seqname; source; feature; pos = (start, stop); score;
                       strand; phase; attributes})
    in
    output_result result

  | other ->
    `error (`wrong_row (pos, s))
  end
  
let rec next ?(pedantic=true) ?(sharp_comments=true) ?(version=`three) p =
  let open Biocaml_transform.Line_oriented in
  let open Result in
  match next_line p with
  | None -> `not_ready
  | Some "" ->
    if pedantic then `error (`empty_line (current_position p)) else `not_ready
  | Some l when sharp_comments && String.(is_prefix (strip l) ~prefix:"#") ->
    `output (`comment String.(sub l ~pos:1 ~len:(length l - 1)))
  | Some l -> parse_row ~version (current_position p) l

let parser ?filename ?pedantic ?version () =
  let name = sprintf "gff_parser:%s" Option.(value ~default:"<>" filename) in
  let module LOP =  Biocaml_transform.Line_oriented  in
  let lo_parser = LOP.parser ?filename () in
  Biocaml_transform.make_stoppable ~name ()
    ~feed:(LOP.feed_string lo_parser)
    ~next:(fun stopped ->
      match next ?pedantic ?version lo_parser with
      | `output r -> `output r
      | `error e -> `error e
      | `not_ready ->
        if stopped then (
          match LOP.finish lo_parser with
          | `ok -> `end_of_stream
          | `error (l, o) ->
            `error (`incomplete_input (LOP.current_position lo_parser, l, o))
        ) else
          `not_ready)
    
    
let printer ?(version=`three) () =
  let module PQ = Biocaml_transform.Printer_queue in
  let printer =
    PQ.make () ~to_string:(function
    | `comment c -> sprintf "#%s\n" c
    | `record t ->
      let escape =
        match version with | `three -> url_escape | `two -> sprintf "%S" in
      let optescape  o =  Option.value_map ~default:"." o ~f:escape in
      String.concat ~sep:"\t" [
        escape t.seqname;
        optescape t.source;
        optescape t.feature;
        sprintf "%d" (fst t.pos);
        sprintf "%d" (snd t.pos);
        Option.value_map ~default:"." ~f:(sprintf "%g") t.score;
        (match t.strand with`plus -> "+" | `minus -> "-"
        | `not_applicable -> "." | `unknown -> "?");
        Option.value_map ~default:"." ~f:(sprintf "%d") t.phase;
        String.concat ~sep:";"
          (List.map t.attributes (fun (k,v) ->
            match version with
            | `three ->
              sprintf "%s=%s" (url_escape k)
                (List.map v url_escape |! String.concat ~sep:",")
            | `two ->
              sprintf "%S %s" k
                (List.map v escape |! String.concat ~sep:",")
           ));
      ] ^ "\n"
    ) in
  Biocaml_transform.make_stoppable ~name:"gff_printer" ()
    ~feed:(fun r -> PQ.feed printer r)
    ~next:(fun stopped ->
      match (PQ.flush printer) with
      | "" -> if stopped then `end_of_stream else `not_ready
      | s -> `output s)

