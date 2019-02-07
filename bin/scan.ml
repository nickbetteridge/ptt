open Common

let pp_kind ppf stat = match stat.Unix.st_kind with
  | Unix.S_REG -> Fmt.string ppf "-"
  | Unix.S_DIR -> Fmt.string ppf "d"
  | Unix.S_CHR -> Fmt.string ppf "c"
  | Unix.S_BLK -> Fmt.string ppf "b"
  | Unix.S_LNK -> Fmt.string ppf "l"
  | Unix.S_FIFO -> Fmt.string ppf "p"
  | Unix.S_SOCK -> Fmt.string ppf "s"

let pp_perm ppf stat =
  let r_perm = Fmt.using (function 0 -> "-" | _ -> "r") Fmt.string in
  let w_perm = Fmt.using (function 0 -> "-" | _ -> "w") Fmt.string in
  let x_perm = Fmt.using (function 0 -> "-" | _ -> "x") Fmt.string in
  Fmt.pf ppf "%a%a%a%a%a%a%a%a%a"
    r_perm (stat.Unix.st_perm land 0x100)
    w_perm (stat.Unix.st_perm land 0x80 )
    x_perm (stat.Unix.st_perm land 0x40 )
    r_perm (stat.Unix.st_perm land 0x20 )
    w_perm (stat.Unix.st_perm land 0x10 )
    x_perm (stat.Unix.st_perm land 0x8  )
    r_perm (stat.Unix.st_perm land 0x4  )
    w_perm (stat.Unix.st_perm land 0x2  )
    x_perm (stat.Unix.st_perm land 0x1  )

let pp_mailbox ppf mailbox =
  let open Mrmime.Mailbox in
  let pp_word ppf = function `Atom x -> Fmt.string ppf x | `String x -> Fmt.pf ppf "%S" x in
  let pp_literal_domain ppf = function
    | IPv4 x -> Fmt.pf ppf "[%a]" Ipaddr.V4.pp x
    | IPv6 x -> Fmt.pf ppf "[IPv6:%a]" Ipaddr.V6.pp x
    | Ext (ldh, v) -> Fmt.pf ppf "[%s:%s]" ldh v in
  let pp_domain ppf = function
    | `Domain lst -> Fmt.(list ~sep:(const string ".") string) ppf lst
    | `Literal x -> Fmt.pf ppf "[%s]" x
    | `Addr x -> pp_literal_domain ppf x in
  let pp_local = Fmt.(list ~sep:(const string ".") pp_word) in
  let pp_elt ppf = function
    | `Dot -> Fmt.string ppf "."
    | `Word x -> pp_word ppf x
    | `Encoded { Mrmime.Encoded_word.data = Ok raw; _ } ->
      (* Handle output, UTF-8, ISO-8859? *)
      Fmt.string ppf raw
    | `Encoded _ -> Fmt.string ppf "<?>" in
  let pp_phrase = Fmt.(list ~sep:(const string " ") pp_elt) in
  match mailbox.name, mailbox.domain with
  | Some name, (domain, []) ->
    Fmt.pf ppf "%a <%a@%a>" pp_phrase name pp_local mailbox.local pp_domain domain
  | Some name, (domain, rest) ->
    Fmt.pf ppf "%a <%a:%a@%a>"
      pp_phrase name
      Fmt.(list ~sep:(const string ",") (prefix (const string "@") pp_domain)) rest
      pp_local mailbox.local
      pp_domain domain
  | None, (domain, []) ->
    Fmt.pf ppf "<%a@%a>" pp_local mailbox.local pp_domain domain
  | None, (domain, rest) ->
    Fmt.pf ppf "<%a:%a@%a>"
      Fmt.(list ~sep:(const string ",") (prefix (const string "@") pp_domain)) rest
      pp_local mailbox.local
      pp_domain domain

let pp_user ppf stat =
  let user = Unix.getpwuid stat.Unix.st_uid in
  Fmt.string ppf user.Unix.pw_name

let pp_group ppf stat =
  let group = Unix.getgrgid stat.Unix.st_gid in
  Fmt.string ppf group.Unix.gr_name

let pp_time =
  let pp = Fmt.(option ~none:(const string "#invalid-date") Ptime.pp) in
  Fmt.using Ptime.of_float_s pp

let pp_size ppf stat = Fmt.int ppf stat.Unix.st_size
let pp_pad n pp = Fmt.using (pad n <.> Fmt.strf "%a" pp) Fmt.string

let parse_header new_line ic =
  let open Angstrom.Buffered in
  let raw = Bytes.create 4096 in
  let rec go = function
    | Partial continue ->
      let len = input ic raw 0 (Bytes.length raw) in
      let raw = sanitize_input new_line raw len in
      let res = if len = 0 then continue `Eof else continue (`String raw) in
      go res
    | Done (_, header) -> close_in ic ; Ok header
    | Fail (_, _, err) -> close_in ic ; Error (`Msg err) in
  go (parse Mrmime.Mail.header)

let get_field
  : type a. a Mrmime.Header.field -> Mrmime.Header.t -> ((a * Mrmime.Location.t) list, [ `Not_found | Rresult.R.msg ]) result
  = fun field header ->
    match Mrmime.Header.get field header with
    | [] -> Error `Not_found
    | lst -> Ok lst

let get_fields fields header =
  let f a (Mrmime.Header.V field) = match a, get_field field header with
    | Ok a, Ok l ->
      Ok (List.map (fun (v, loc) -> Mrmime.Header.B (field, v, loc)) l @ a)
    | Error _, _ -> a
    | Ok a, Error _ ->
      let field = Mrmime.Header.unsafe (Mrmime.Header.field_to_string field) in
      match get_field field header with
      | Ok l -> Ok (List.map (fun (v, loc) -> Mrmime.Header.B (field, v, loc)) l @ a)
      | Error e -> Error e in
  List.fold_left f (Ok []) fields

let pp_value_of_field : type a. a Mrmime.Header.field -> a Fmt.t = function
  | Mrmime.Header.From -> Fmt.(list ~sep:(const string ", ") pp_mailbox)
  | field -> Mrmime.Header.pp_value_of_field field

let pp_binding ppf (Mrmime.Header.B (field, v, _)) =
  Fmt.pf ppf "%a %a"
    (pp_pad 15 Fmt.(suffix (const string ":") (using Mrmime.Header.field_to_string string))) field
    (pp_value_of_field field) v

module Status = struct
  let ok = Fmt.const Fmt.string "[OK]" |> Fmt.styled `Green
  let error = Fmt.const Fmt.string "[ERROR]" |> Fmt.styled `Red
  let wait = Fmt.const Fmt.string "[...]" |> Fmt.styled `Yellow
end

let print_fields maildir new_line message fields =
  let open Rresult.R in
  match in_channel_of_message maildir message >>= parse_header new_line with
  | Ok (_content, header, _rest) ->
    let fields = List.map Mrmime.Header.field_of_string fields in
    let bindings = List.map
        Rresult.R.(fun field -> field
                    >>=
                    (fun (Mrmime.Header.V field) ->
                       get_field field header
                       |> function
                       | Ok values ->
                         Ok (List.map (fun (v, loc) -> Mrmime.Header.B (field, v, loc)) values)
                       | Error `Not_found -> Error (`Not_found (Mrmime.Header.V field))
                       | Error (`Msg err) -> Rresult.R.error_msg err))
        (fields :> (Mrmime.Header.value,
                    [ `Not_found of Mrmime.Header.value
                    | Rresult.R.msg ]) result list) in
    List.iter
      (function
        | Ok bindings -> List.iter (Fmt.pr "%a\n%!" pp_binding) bindings
        | Error (`Msg err) -> Fmt.pr "%a: %s.\n%!" Status.error () err
        | Error (`Not_found (Mrmime.Header.V field)) ->
          Fmt.pr "%a: %s not found.\n%!"
            Status.error ()
            (Mrmime.Header.field_to_string field))
      bindings
  | Error _ ->
    Fmt.pr "%a: header of %a can not be parser"
      Status.error () Maildir.pp_message message

let print maildir new_line fields () message =
  let path = Maildir_unix.get maildir message in
  let stat = Unix.stat (Fpath.to_string path) in
  Fmt.pr "%a%a %a %a %a %a %a\n%!"
    pp_kind stat
    pp_perm stat
    (pp_pad 10 pp_user) stat
    (pp_pad 10 pp_group) stat
    (pp_pad 10 pp_size) stat
    pp_time stat.Unix.st_mtime
    Maildir.pp_message message ;
  if List.length fields > 0
  then print_fields maildir new_line message fields ; ()

let run () maildir_path host only_new new_line fields =
  let maildir = Maildir.create ~pid:(Unix.getpid ()) ~host ~random maildir_path in

  if only_new
  then Maildir_unix.scan_only_new (print maildir new_line fields) () Maildir_unix.fs maildir
  else Maildir_unix.fold (print maildir new_line fields) () Maildir_unix.fs maildir ;

  Ok ()

open Cmdliner

let host =
  let doc = "Hostname of machine." in
  Arg.(value & opt Conv.hostname (Unix.gethostname ()) & info [ "h"; "host" ] ~docv:"<host>" ~doc)

let only_new =
  let doc = "Lists only new messages." in
  Arg.(value & flag & info [ "only-new" ] ~doc)

let fields =
  let doc = "Fields to extract." in
  Arg.(value & opt (list Conv.field) [] & info [ "w"; "with" ] ~docv:"<fields>" ~doc)

let command =
  let doc = "Scan tool." in
  let exits = Term.default_exits in
  let man =
    [ `S Manpage.s_description
    ; `P "Lists mails available on <maildir> database." ] in
  Term.(pure run
        $ Arguments.setup_fmt_and_logs
        $ Arguments.maildir_path
        $ host
        $ only_new
        $ Arguments.new_line
        $ fields),
  Term.info "scan" ~doc ~exits ~man
