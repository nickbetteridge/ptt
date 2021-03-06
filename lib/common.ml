open Colombe.Sigs
open Sigs
open Rresult

let ( <.> ) f g = fun x -> f (g x)

module Make
    (Scheduler : SCHEDULER)
    (IO : IO with type 'a t = 'a Scheduler.s)
    (Flow : FLOW with type 'a s = 'a IO.t)
    (Resolver : RESOLVER with type 'a s = 'a IO.t)
    (Random : RANDOM with type 'a s = 'a IO.t)
= struct
  type 'w resolver =
    { gethostbyname : 'a. 'w -> [ `host ] Domain_name.t -> (Ipaddr.V4.t, [> R.msg ] as 'a) result IO.t
    ; getmxbyname   : 'a. 'w -> [ `host ] Domain_name.t -> (Dns.Rr_map.Mx_set.t, [> R.msg ] as 'a) result IO.t
    ; extension     : 'a. 'w -> string -> string -> (Ipaddr.V4.t, [> R.msg ] as 'a) result IO.t }

  type 'g random = ?g:'g -> bytes -> unit IO.t
  type 'a consumer = 'a option -> unit IO.t

  let resolver =
    let open Resolver in
    { gethostbyname; getmxbyname; extension; }

  let generate =
    let open Random in
    generate

  let return = IO.return
  let ( >>= ) = IO.bind
  let ( >|= ) x f = x >>= fun x -> return (f x)
  let ( >>? ) x f = x >>= function
    | Ok x -> f x
    | Error err -> return (Error err)

  let scheduler =
    let open Scheduler in
    { bind= (fun x f -> inj (prj x >>= fun x -> prj (f x)))
    ; return= (fun x -> inj (return x)) }

  let rdwr =
    let open Scheduler in
    { Colombe.Sigs.rd= (fun flow buf off len -> inj (Flow.recv flow buf off len))
    ; Colombe.Sigs.wr= (fun flow buf off len -> inj (Flow.send flow buf off len)) }

  let run
    : Flow.t -> ('a, 'err) Colombe.State.t -> ('a, [> `Error of 'err | `Connection_close ]) result IO.t
    = fun flow m ->
      let rec go = function
        | Colombe.State.Read { buffer; off; len; k; } ->
          (rdwr.rd flow buffer off len |> Scheduler.prj >>= function
            | 0 -> IO.return (Error `Connection_close)
            (* TODO(dinosaure): [rd] should returns [ `Close | `Len of int ]
               instead when [0] is specific to a file-descriptor. *)
            | n -> (go <.> k) n)
        | Colombe.State.Write { buffer; off; len; k; } ->
          rdwr.wr flow buffer off len |> Scheduler.prj >>= fun () -> go (k len)
        | Colombe.State.Return v -> IO.return (Ok v)
        | Colombe.State.Error err -> IO.return (Error (`Error err)) in
      go m

  let list_fold_left_s ~f a l =
    let rec go a = function
      | [] -> IO.return a
      | x :: r -> f a x >>= fun a -> go a r in
    go a l

  let recipients_are_reachable ~ipv4 w recipients =
    let open Colombe in
    let fold m { Dns.Mx.mail_exchange; Dns.Mx.preference; } =
      resolver.gethostbyname w mail_exchange >>= function
      | Ok mx_ipaddr ->
        let mx_ipaddr = Ipaddr.V4 mx_ipaddr in
        (* TODO: [gethostbyname] should return a [Ipaddr.t]. *)
        IO.return (Mxs.add { Mxs.preference; Mxs.mx_ipaddr
                           ; Mxs.mx_domain= Some mail_exchange; } m)
      | Error (`Msg _err) -> IO.return m in
    let rec go acc = function
      | [] -> IO.return acc
      | Forward_path.Postmaster :: r ->
        go (Mxs.(singleton (v ~preference:0 (Ipaddr.V4 ipv4))) :: acc) r
      | Forward_path.Forward_path { Path.domain= Domain.Domain v; _ } :: r
      | Forward_path.Domain (Domain.Domain v) :: r ->
        ( try
            let domain = Domain_name.(host_exn <.> of_strings_exn) v in
            resolver.getmxbyname w domain >>= function
            | Ok m ->
              list_fold_left_s ~f:fold Mxs.empty
                (Dns.Rr_map.Mx_set.elements m) >>= fun s ->
              go (s :: acc) r
            | Error (`Msg _err) -> go acc r
          with _exn -> go (Mxs.empty :: acc) r )
      | Forward_path.Forward_path { Path.domain= Domain.IPv4 mx_ipaddr; _ } :: r
      | Forward_path.Domain (Domain.IPv4 mx_ipaddr) :: r ->
        go (Mxs.(singleton (v ~preference:0 (Ipaddr.V4 mx_ipaddr))) :: acc) r
      | Forward_path.Forward_path { Path.domain= Domain.IPv6 _; _ } :: r
      | Forward_path.Domain (Domain.IPv6 _) :: r -> go acc r
      | Forward_path.Forward_path { Path.domain= Domain.Extension (ldh, v); _ } :: r
      | Forward_path.Domain (Domain.Extension (ldh, v)) :: r ->
        resolver.extension w ldh v >>= function
        | Ok mx_ipaddr -> go (Mxs.(singleton (v ~preference:0 (Ipaddr.V4 mx_ipaddr))) :: acc) r
        | Error (`Msg _err) -> go acc r in
    go [] recipients >>= (IO.return <.> List.for_all (fun m -> not (Mxs.is_empty m)))

  let dot = Some (".\r\n", 0, 3)

  let receive_mail ?(limit= 0x100000) flow ctx m producer =
    let rec go count () =
      if count >= limit
      then return (Error `Too_big_data)
      else run flow (m ctx) >>? function
      | ".." -> producer dot >>= go (count + 3)
      | "." -> producer None >>= fun () -> return (Ok ())
      | v ->
        let len = String.length v in
        producer (Some (v ^ "\r\n", 0, len + 2)) >>= go (count + len + 2) in
    go 0 ()

  let resolve_recipients ~domain w relay_map recipients =
    let module Resolved = Map.Make(struct
        type t = [ `Ipaddr of Ipaddr.t | `Domain of ([ `host ] Domain_name.t * Mxs.t) ]

        let compare a b = match a, b with
          | `Ipaddr a, `Ipaddr b -> Ipaddr.compare a b
          | `Domain (_, mxs_a), `Domain (_, mxs_b) ->
            let { Mxs.mx_ipaddr= a; _ } = Mxs.choose mxs_a in
            let { Mxs.mx_ipaddr= b; _ } = Mxs.choose mxs_b in
            Ipaddr.compare a b
          | `Ipaddr a, `Domain (_, mxs) ->
            let { Mxs.mx_ipaddr= b; _ } = Mxs.choose mxs in
            Ipaddr.compare a b
          | `Domain (_, mxs), `Ipaddr b ->
            let { Mxs.mx_ipaddr= a; _ } = Mxs.choose mxs in
            Ipaddr.compare a b
      end) in
    let postmaster = [ `Atom "Postmaster" ] in
    let unresolved, resolved = Aggregate.aggregate_by_domains ~domain recipients in
    let unresolved, resolved = Relay_map.expand relay_map unresolved resolved in
    let fold resolved (domain, recipients) =
      resolver.getmxbyname w domain >>= function
      | Error (`Msg _err) -> IO.return resolved
      | Ok mxs ->
        let fold mxs { Dns.Mx.mail_exchange; Dns.Mx.preference; } =
          resolver.gethostbyname w mail_exchange >>= function
          | Ok mx_ipaddr ->
            let mxs = Mxs.(add (v ~preference ~domain:mail_exchange (Ipaddr.V4 mx_ipaddr)) mxs) in
            IO.return mxs
          | Error (`Msg _err) -> IO.return mxs in
        list_fold_left_s ~f:fold Mxs.empty (Dns.Rr_map.Mx_set.elements mxs) >>= fun mxs ->
        if Mxs.is_empty mxs
        then IO.return resolved
        else
          let { Mxs.mx_ipaddr; _ } = Mxs.choose mxs in
          match recipients with
          | `All -> IO.return (Resolved.add (`Domain (domain, mxs)) `All resolved)
          | `Local l0 ->
            ( match Resolved.find_opt (`Ipaddr mx_ipaddr) resolved with
              | None -> IO.return (Resolved.add (`Domain (domain, mxs)) (`Local l0) resolved)
              | Some `All -> IO.return resolved
              | Some (`Local l1) ->
                let vs = List.sort_uniq (Emile.compare_local ~case_sensitive:true) (l0 @ l1) in
                IO.return (Resolved.add (`Domain (domain, mxs)) (`Local vs) resolved)
              | Some `Postmaster ->
                IO.return (Resolved.add (`Domain (domain, mxs)) (`Local (postmaster :: l0)) resolved) )
          | `Postmaster -> match Resolved.find_opt (`Ipaddr mx_ipaddr) resolved with
            | Some `Postmaster | Some `All -> IO.return resolved
            | Some (`Local l0) ->
              if List.exists (Emile.equal_local ~case_sensitive:true postmaster) l0
              then IO.return resolved
              else IO.return (Resolved.add (`Domain (domain, mxs)) (`Local (postmaster :: l0)) resolved)
            | None ->
              IO.return (Resolved.add (`Domain (domain, mxs)) (`Local [ postmaster ]) resolved) in
    let open Aggregate in
    let resolved = By_ipaddr.fold (fun k v m -> Resolved.add (`Ipaddr k) v m) resolved Resolved.empty in
    list_fold_left_s ~f:fold resolved (By_domain.bindings unresolved) >|= Resolved.bindings
end
