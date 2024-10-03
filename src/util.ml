let pyprint x =
  let open Pyops in
  let builtins = Py.import "builtins" in
  let p = builtins.&("print") in
  let _ = p [| x |] in
  ()

include Ppx_yojson_conv_lib.Yojson_conv
module Get_log = (val Logs.src_log Logs.(Src.create "get-log"))

let get ~headers uri =
  let open Lwt in
  let open Lwt.Syntax in
  let open Cohttp in
  let open Cohttp_lwt_unix in
  let* response, body_stream = Client.get ~headers uri in
  let* resp_body_raw = Cohttp_lwt.Body.to_string body_stream in
  let resp_body_json = Yojson.Safe.from_string resp_body_raw in
  match Response.status response with
  | #Code.success_status -> Lwt.return resp_body_json
  | #Code.informational_status as status ->
      Get_log.err (fun k ->
          k "informational_status: %s" (Code.string_of_status status));
      Lwt.fail_invalid_arg @@ Code.string_of_status status
  | #Code.redirection_status as status ->
      Get_log.err (fun k ->
          k "redirection_status: %s" (Code.string_of_status status));
      Lwt.fail_invalid_arg @@ Code.string_of_status status
  | #Code.client_error_status as status ->
      Get_log.err (fun k ->
          k "client_error_status: %s" (Code.string_of_status status));
      Lwt.fail_invalid_arg @@ Code.string_of_status status
  | #Code.server_error_status as status ->
      Get_log.err (fun k ->
          k "server_error_status: %s" (Code.string_of_status status));
      Lwt.fail_invalid_arg @@ Code.string_of_status status
  | `Code i as status ->
      Get_log.err (fun k -> k "unknown code: %s" (Code.string_of_status status));
      Lwt.fail_invalid_arg @@ Code.string_of_status status
