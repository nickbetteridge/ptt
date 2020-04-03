let () = Printexc.record_backtrace true
let reporter = Logs_fmt.reporter ()
let () = Fmt.set_utf_8 Fmt.stdout true
let () = Fmt.set_utf_8 Fmt.stderr true
let () = Fmt.set_style_renderer Fmt.stdout `Ansi_tty
let () = Fmt.set_style_renderer Fmt.stderr `Ansi_tty
let () = Logs.set_level ~all:true (Some Logs.Debug)
let () = Logs.set_reporter reporter
let () = Nocrypto_entropy_unix.initialize ()

let ( <.> ) f g = fun x -> f (g x)

module Random = struct
  type g = unit

  let generate ?g:_ len =
    let ic = open_in "/dev/urandom" in
    let rs = Bytes.create len in
    really_input ic rs 0 len ; close_in ic ;
    Cstruct.of_bytes rs
end

open Rresult

module Resolver = struct
  type +'a s = 'a Lwt.t
  type t = Dns_client_lwt.t

  let gethostbyname t v = Dns_client_lwt.gethostbyname t v
  let getmxbyname t v =
    let open Lwt_result in
    Dns_client_lwt.getaddrinfo t Dns.Rr_map.Mx v >|= fun (_, mxs) -> mxs
  let extension _t _ldh _v =
    Lwt.return (R.error_msgf "Impossible to resolve [%s:%s]" _ldh _v)
end

module Server = Lipap.Make(Random)(Mclock)(Pclock)(Resolver)(Tcpip_stack_socket)

let load_file filename =
  let open Rresult in
  Bos.OS.File.read filename >>= fun contents ->
  R.ok (Cstruct.of_string contents)

let cert =
  let open Rresult in
  load_file (Fpath.v "server.pem") >>= fun raw ->
  X509.Certificate.decode_pem raw

let cert = Rresult.R.get_ok cert

let private_key =
  let open Rresult in
  load_file (Fpath.v "server.key") >>= fun raw ->
  X509.Private_key.decode_pem raw >>= fun (`RSA v) -> R.ok v

let private_key = Rresult.R.get_ok private_key

let authenticator _username _password =
  Ptt_tuyau.Lwt_backend.Lwt_scheduler.inj (Lwt.return true)
let authenticator =
  Ptt.Authentication.v authenticator

let fiber ~domain map =
  let open Lwt.Infix in
  Tcpip_stack_socket.TCPV4.connect None >>= fun tcpv4 ->
  Tcpip_stack_socket.UDPV4.connect None >>= fun udpv4 ->
  Tcpip_stack_socket.connect [] udpv4 tcpv4 >>= fun stackv4 ->
  let conf =
    { Tuyau_mirage_tcp.stack= stackv4
    ; Tuyau_mirage_tcp.keepalive= None
    ; Tuyau_mirage_tcp.nodelay= false
    ; Tuyau_mirage_tcp.port= 4242 } in
  let info =
    { Ptt.SMTP.domain
    ; Ptt.SMTP.ipv4= Ipaddr.V4.any
    ; Ptt.SMTP.tls= Tls.Config.server
          ~certificates:(`Single ([ cert ], private_key))
          ~authenticator:Ptt.Authentication.null ()
    ; Ptt.SMTP.client_x509_authenticator=Ptt.Authentication.null
    ; Ptt.SMTP.zone= Mrmime.Date.Zone.GMT
    ; Ptt.SMTP.size= 0x1000000L } in
  let resolver = Dns_client_lwt.create ~clock:Mclock.elapsed_ns () in
  Server.fiber stackv4 resolver () (Digestif.BLAKE2B 64) conf map info authenticator [ Ptt.Mechanism.PLAIN ]

let romain_calascibetta =
  let open Mrmime.Mailbox in
  Local.[ w "romain"; w "calascibetta" ] @ Domain.(domain, [ a "gmail"; a "com" ])

let () =
  let domain = Domain_name.(host_exn <.> of_string_exn) "x25519.net" in
  let map = Ptt.Relay_map.empty ~postmaster:romain_calascibetta ~domain in
  let map =
    let open Mrmime.Mailbox in
    Ptt.Relay_map.add
      ~local:(Local.(v [ w "romain"; w "calascibetta" ]))
      romain_calascibetta map in
  Lwt_main.run (fiber ~domain map)
