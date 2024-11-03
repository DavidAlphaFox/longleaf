module Log = (val Logs.src_log Logs.(Src.create "longleaf"))
module Util = Util
module Backend = Backend
module Environment = Environment
module Trading_types = Trading_types
module Market_data_api = Market_data_api
module Ticker = Ticker
module Time = Time
module Lots_of_words = Lots_of_words

(* module Tickers = struct *)
(*   let get_tickers () = *)
(*     let open Pyops in *)
(*     let sp600_url = *)
(*       {|https://en.wikipedia.org/wiki/List_of_S%26P_600_companies|} *)
(*       |> Py.String.of_string *)
(*     in *)
(*     let pandas = Py.import "pandas" in *)
(*     let read_html = pandas.&("read_html") in *)
(*     let tables = read_html [| sp600_url |] in *)
(*     let col = tables.![Py.Int.of_int 0] in *)
(*     let ticker_symbols = col.!$["Symbol"] in *)
(*     Py.List.to_array_map Py.Object.to_string ticker_symbols *)
(* end *)

module Tests (Conn : Util.ALPACA_SERVER) = struct
  module MDA = Market_data_api.Make (Conn)

  let download_test () =
    let history_request : Market_data_api.Historical_bars_request.t =
      {
        timeframe = Trading_types.Timeframe.day;
        start = Time.of_ymd "2012-06-06";
        symbols = [ "MSFT"; "GOOG"; "NVDA"; "AAPL" ];
      }
    in
    let historical_bars = MDA.Stock.historical_bars history_request in
    historical_bars

  let double_top_test symbols =
    let history_request : Market_data_api.Historical_bars_request.t =
      {
        timeframe = Trading_types.Timeframe.day;
        start = Time.of_ymd "2024-08-06";
        symbols;
      }
    in
    let historical_bars = MDA.Stock.historical_bars history_request in
    historical_bars
end

module DoubleTopRun (Mutex : Backend.MUTEX) = struct
  let top ~eio_env ~longleaf_env =
    Eio.Switch.run @@ fun switch ->
    let module Common_eio_stuff = struct
      let switch = switch
      let longleaf_env = longleaf_env
      let eio_env = eio_env

      module Mutex = Mutex
    end in
    let module Backtesting = Backend.Backtesting (struct
      include Common_eio_stuff

      let bars =
        Yojson.Safe.from_file "data/test_hexahydroxy_propagation"
        |> Trading_types.Bars.t_of_yojson

      let symbols = Trading_types.Bars.tickers bars
    end) in
    let module Alpaca =
      Backend.Alpaca
        (struct
          include Common_eio_stuff

          let bars = Trading_types.Bars.empty

          let symbols =
            [
              "NVDA";
              "TSLA";
              "AAPL";
              "MSFT";
              "NFLX";
              "META";
              "AMZN";
              "AMD";
              "AVGO";
              "ELV";
              "UNH";
              "MU";
              "V";
              "GOOG";
              "SMCI";
              "MSTR";
              "UBER";
              "LLY";
            ]
        end)
        (Ticker.FiveSecond)
    in
    let module Backend = Alpaca in
    let module Strategy = Double_top.DoubleTop (Backend) in
    let res = Strategy.run () in
    Eio.traceln "%s" res;
    ()
end

let top eio_env =
  Util.yojson_safe @@ fun () ->
  CalendarLib.Time_Zone.change (UTC_Plus (-5));
  let longleaf_env = Environment.make () in
  let module Mutex = Backend.Mutex in
  let domain_manager = Eio.Stdenv.domain_mgr eio_env in
  let run_strategy () =
    let module Run = DoubleTopRun (Mutex) in
    Eio.Domain_manager.run domain_manager @@ fun () ->
    Run.top ~eio_env ~longleaf_env
  in
  let run_server () =
    let set_mutex = Mutex.set_mutex in
    Eio.Domain_manager.run domain_manager @@ fun () ->
    Gui.top ~set_mutex eio_env
  in
  Eio.Fiber.all [ run_strategy; run_server ]
