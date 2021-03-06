include BytesLabels

(* This is adapted from janestreet's Base *)
let split str ~on:c =
  let len = String.length str in
  let rec loop acc last_pos pos =
    if pos = -1 then
      sub str ~pos:0 ~len:last_pos :: acc
    else
    if str.[pos] = c then
      let pos1 = pos + 1 in
      let sub_str = sub str ~pos:pos1 ~len:(last_pos - pos1) in
      loop (sub_str :: acc) pos (pos - 1)
    else loop acc last_pos (pos - 1)
  in
  loop [] len (len - 1)

let normalize t i =
  if i < 0
  then i + length t
  else i

let slice t start stop =
  let stop = if stop = 0 then length t else stop in
  let pos = normalize t start in
  let len = (normalize t stop) - pos in
  sub t ~pos ~len

let rsplit2_exn line ~on:delim =
  let pos = rindex line delim in
  (sub line ~pos:0 ~len:pos,
   sub line ~pos:(pos+1) ~len:(String.length line - pos - 1)
  )

let rsplit2 line ~on =
  try Some (rsplit2_exn line ~on) with Not_found -> None
