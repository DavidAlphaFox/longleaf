module Log = (val Logs.src_log Logs.(Src.create "longleaf"))

module Tickers = struct
  let get_tickers () =
    let open Pyops in
    let sp600_url =
      {|https://en.wikipedia.org/wiki/List_of_S%26P_600_companies|}
      |> Py.String.of_string
    in
    let pandas = Py.import "pandas" in
    let read_html = pandas.&("read_html") in
    let tables = read_html [| sp600_url |] in
    let col = tables.![Py.Int.of_int 0] in
    let ticker_symbols = col.!$["Symbol"] in
    Py.List.to_array_map Py.Object.to_string ticker_symbols
end

let process_json (x : Yojson.Safe.t) =
  let env = Environment.make () in
  Log.app (fun k -> k "%a" Environment.pp env);
  let _ = Trading_api.Accounts.get_account env in
  let resp_body =
    Trading_types.(
      Lwt_main.run
      @@ Market_data_api.Stock.historical_bars env (Timeframe.hour 1)
           ~start:(Time.of_ymd "2024-08-28") [ "AAPL" ])
  in
  Log.app (fun k -> k "resp_body longleaf: %a" Trading_types.Bars.pp resp_body);
  Dataframe.of_json x

let top () =
  let open Lwt.Syntax in
  let env = Environment.make () in
  let* latest_bars = Market_data_api.Stock.latest_bars env [ "AAPL" ] in
  Lwt.return (Cohttp.Code.status_of_code 200)
