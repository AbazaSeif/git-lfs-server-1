(*
 * Copyright (c) 2015 Stanislav Artemkin <artemkin@gmail.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
*)

open Core.Std
open Async.Std
open Cohttp
open Cohttp_async

module Json = struct
  let error msg =
    let msg = `Assoc [ "message", `String msg ] in
    Yojson.pretty_to_string msg

  let metadata ~oid ~size ~self_url ~download_url =
    let msg = `Assoc [
        "oid", `String oid;
        "size", `Intlit (Int64.to_string size);
        "_links", `Assoc [
          "self", `Assoc [ "href", `String (Uri.to_string self_url) ];
          "download", `Assoc [ "href", `String (Uri.to_string download_url) ]
        ]
      ] in
    Yojson.pretty_to_string msg
end

let is_sha256_hex_digest str =
  if String.length str <> 64 then false
  else String.for_all str ~f:Char.is_alphanum

let add_content_type headers content_type =
  Header.add headers "content-type" content_type

let respond_with_string ~meth ~code str =
  let headers = add_content_type (Header.init ()) "application/vnd.git-lfs+json" in
  let body = match meth with `GET -> `String str | `HEAD -> `Empty in
  Server.respond ~headers ~body code

let respond_not_found ~meth ~msg =
  respond_with_string ~meth
    ~code:`Not_found @@ Json.error msg

let respond_not_implemented () =
  respond_with_string ~meth:`GET
    ~code:`Not_implemented @@ Json.error "Not implemented"

let get_oid_path ~oid =
  let oid02 = String.prefix oid 2 in
  let oid24 = String.sub oid ~pos:2 ~len:2 in
  Filename.of_parts [oid02; oid24; oid]

let get_object_filename ~root ~oid =
  Filename.of_parts [root; "/objects"; get_oid_path ~oid]

(* TODO fix this *)
let fix_uri ~port uri =
  let uri = Uri.with_scheme uri (Some "http") in
  Uri.with_port uri (if port = 80 then None else Some port)

let respond_object_metadata ~root ~port ~uri ~meth ~oid  =
  let path = get_object_filename ~root ~oid in
  try_with (fun () -> Unix.stat path) >>= function
  | Error _ -> respond_not_found ~meth ~msg:"Object not found"
  | Ok stat ->
    let self_url = fix_uri ~port uri in
    let download_url = Uri.with_path self_url @@ Filename.concat "/data/objects" oid in
    respond_with_string ~meth ~code:`OK
    @@ Json.metadata ~oid ~size:(Unix.Stats.size stat) ~self_url ~download_url

let respond_object ~root ~meth ~oid =
  let filename = get_object_filename ~root ~oid in
  Monitor.try_with ~run:`Now
    (fun () ->
       Reader.open_file filename
       >>= fun rd ->
       let headers = add_content_type (Header.init ()) "application/octet-stream" in
       match meth with
       | `GET ->
         Server.respond ~headers ~body:(`Pipe (Reader.pipe rd)) `OK
       | `HEAD ->
         Reader.close rd >>= fun () ->
         Server.respond ~headers ~body:`Empty `OK)
  >>= function
  | Ok res -> return res
  | Error _ -> respond_not_found ~meth ~msg:"Object not found"

let oid_from_path path =
  match String.rsplit2 path ~on:'/' with
  | Some ("/objects", oid) ->
    if is_sha256_hex_digest oid then Some (oid, `Metadata) else None
  | Some ("/data/objects", oid) ->
    if is_sha256_hex_digest oid then Some (oid, `Object) else None
  | _ -> None

let serve_client ~root ~port ~body:_ _sock req =
  let uri = Request.uri req in
  if Option.is_none (Uri.host uri) then
    respond_with_string ~meth:`GET
      ~code:`Bad_request @@ Json.error "Wrong host"
  else
    let path = Uri.path uri in
    let meth = Request.meth req in
    let oid = oid_from_path path in
    match meth, oid with
    | (`GET as meth), Some (oid, `Metadata) | (`HEAD as meth), Some (oid, `Metadata) ->
      respond_object_metadata ~root ~port ~uri ~meth ~oid
    | (`GET as meth), Some (oid, `Object) | (`HEAD as meth), Some (oid, `Object) ->
      respond_object ~root ~meth ~oid
    | (`GET as meth), None | (`HEAD as meth), None ->
      respond_not_found ~meth ~msg:"Wrong path"
    | `POST, _ -> respond_not_implemented ()
    | _ -> respond_not_implemented ()

let start_server ~root ~host ~port () =
  eprintf "Listening for HTTP on port %d\n" port;
  Unix.Inet_addr.of_string_or_getbyname host
  >>= fun host ->
  let listen_on = Tcp.Where_to_listen.create
      ~socket_type:Socket.Type.tcp
      ~address:(`Inet (host, port))
      ~listening_on:(fun _ -> port)
  in
  Server.create
    ~on_handler_error:`Raise
    listen_on
    (serve_client ~root ~port)
  >>= fun _ -> Deferred.never ()

let () =
  Command.async_basic
    ~summary:"Start a Git LFS server"
    Command.Spec.(
      empty
      +> anon (maybe_with_default "./.lfs" ("root" %: string))
      +> flag "-s" (optional_with_default "127.0.0.1" string) ~doc:"address IP address to listen on"
      +> flag "-p" (optional_with_default 8080 int) ~doc:"port TCP port to listen on"
    )
    (fun root host port -> start_server ~root ~host ~port)
  |> Command.run
