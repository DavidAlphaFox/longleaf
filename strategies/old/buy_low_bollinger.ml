open Trading_types

module DT_Status = struct
  type t = Placed of (int * Order.t) | Waiting [@@deriving show]
end

type state = DT_Status.t State.t

module Conditions = struct
  module Parameters = struct
    (* let min_dip = 0.98 *)
    (* let lower_now_band = 0.99 *)
    (* let upper_now_band = 1.01 *)
    let stop_loss_multiplier = 0.5
    let profit_multiplier = 1.04
    let max_holding_period = 600

    (* let window_size = 20 *)
    (* let lookback = 120 *)

    (* The amount of periods necessary between now and the triggering peak *)
    let min_time_gap = max_holding_period
  end

  module P = Parameters

  let below_bollinger (indicators : Indicators.t) symbol
      (current_price : Item.t) =
    let last_price = Item.last current_price in
    let lower_bollinger =
      Indicators.get_instrument indicators symbol
      |> Option.get_exn_or "low_bollinger: expected to get indicators"
      |> Vector.top
      |> Option.get_exn_or
           "low_bollinger: expected to have data present in indicator"
      |> Indicators.Point.lower_bollinger
    in
    match last_price <=. lower_bollinger with
    | true -> Some (lower_bollinger -. last_price)
    | false -> None

  let crash_block (indicators : Indicators.t) symbol most_recent_price =
    let open Option in
    let* indicators = Indicators.get_instrument indicators symbol in
    let* point = Vector.top indicators in
    let current_price = Item.last most_recent_price in
    if current_price /. Indicators.Point.sma_5 point >=. 0.95 then Some `Pass
    else None

  (* Only buy if RSI is less than 40 *)
  let small_rsi (indicators : Indicators.t) symbol =
    let open Option in
    let* indicators = Indicators.get_instrument indicators symbol in
    let* point = Vector.top indicators in
    if Indicators.Point.relative_strength_index point <=. 40.0 then Some `Pass
    else None

  let above_awesome (indicators : Indicators.t) symbol =
    let open Option in
    let* indicators = Indicators.get_instrument indicators symbol in
    let* point = Vector.top indicators in
    if Indicators.Point.awesome_oscillator point >=. 1.0 then Some `Pass
    else None

  let above_awesome_slow (indicators : Indicators.t) symbol =
    let open Option in
    let* indicators = Indicators.get_instrument indicators symbol in
    let* point = Vector.top indicators in
    if Indicators.Point.awesome_slow point >=. 1.0 then Some `Pass else None

  (* We only want to buy if FSO %K is less than 50 *)
  let small_fso (indicators : Indicators.t) symbol =
    let open Option in
    let* indicators = Indicators.get_instrument indicators symbol in
    let* point = Vector.top indicators in
    if Indicators.Point.fast_stochastic_oscillator_k point >=. 50.0 then None
    else Some `Pass

  module Sell_reason = struct
    type t =
      | Profited of float
      | HoldingPeriod of float
      | StopLoss of float
      | FSO_High of float
      | HoldBelowBollinger
      | Hold
    [@@deriving show { with_path = false }]

    let make ~time_held ~current_price ~(state : state)
        ~(buying_order : Order.t) ~price_difference =
      (* let below_bollinger = *)
      (*   below_bollinger state.indicators buying_order.symbol *)
      (*   @@ Bars.Latest.get state.latest buying_order.symbol *)
      (*   |> function *)
      (*   | Some _ -> true *)
      (*   | None -> false *)
      (* in *)
      let fso_pd =
        Indicators.get_instrument state.indicators buying_order.symbol
        |> Option.get_exn_or "bollinger: Sell_reason.make"
        |> Vector.top
        |> Option.get_exn_or "boll: Sell_reason.make"
        |> Indicators.Point.fast_stochastic_oscillator_d
      in
      (* let fso_pk = *)
      (*   Indicators.get state.indicators buying_order.symbol *)
      (*   |> Option.get_exn_or "bollinger: Sell_reason.make" *)
      (*   |> Vector.top *)
      (*   |> Option.get_exn_or "boll: Sell_reason.make" *)
      (*   |> Indicators.Point.fso_pk *)
      (* in *)
      (* if current_price >. P.profit_multiplier *. buying_order.price then *)
      (*   Profited price_difference *)
      if fso_pd >=. 90.0 then FSO_High price_difference
        (* if (fso_pd >=. 90.0 && fso_pk >=. 55.0) then FSO_High price_difference *)
        (* if fso_pk >=. 95.0 then FSO_High price_difference *)
        (* else if below_bollinger then HoldBelowBollinger *)
      else if time_held > P.max_holding_period then
        HoldingPeriod price_difference
      else if current_price <. P.stop_loss_multiplier *. buying_order.price then
        StopLoss price_difference
      else Hold
  end
end

module BuyLowBollinger (Backend : Backend.S) : Strategy.S = struct
  let shutdown () =
    Eio.traceln "Shutdown command NYI";
    ()

  let init_state = Backend.init_state DT_Status.Waiting

  module SU = Strategy_utils.Make (Backend)
  module P = Conditions.P

  let consider_buying ~(state : state) ~(qty : Instrument.t -> int) symbol =
    let open Option.Infix in
    (* let* price_history = Bars.get history symbol in *)
    let* most_recent_price =
      Bars.Latest.get state.latest symbol |> function
      | Ok x -> Some x
      | Error _ -> None
    in
    let* amt_below_bollinger =
      let* _ =
        Conditions.crash_block state.indicators symbol most_recent_price
      in
      let* amt_below_bollinger =
        Conditions.below_bollinger state.indicators symbol most_recent_price
      in
      let* _ = Conditions.small_rsi state.indicators symbol in
      let* _ = Conditions.above_awesome state.indicators symbol in
      let* _ = Conditions.above_awesome_slow state.indicators symbol in
      let* _ = Conditions.small_fso state.indicators symbol in
      Some amt_below_bollinger
    in
    let order =
      let side = Side.Buy in
      let tif = TimeInForce.GoodTillCanceled in
      let order_type = OrderType.Market in
      let qty = qty symbol in
      let price = Item.last most_recent_price in
      let timestamp = Item.timestamp most_recent_price in
      let reason =
        [
          Format.asprintf "Buying (%a): Below bollinger band" Time.pp timestamp;
        ]
      in
      Order.make ~symbol ~tick:state.tick ~side ~tif ~order_type ~qty ~price
        ~timestamp ~reason ~profit:None
    in
    (* Eio.traceln "@[%a@]@." Order.pp order; *)
    Some (order, amt_below_bollinger)

  (* The maximum amount of a share that can be purchased at the current price with *)
  (*  pct of cash available *)
  let qty (state : state) pct symbol =
    let cash_available = Backend_position.get_cash state.positions in
    match cash_available >=. 0.0 with
    | true ->
        let tenp = cash_available *. pct in
        let current_price = State.price state symbol in
        let max_amt = tenp /. current_price in
        if max_amt >=. 1.0 then Float.round max_amt |> Float.to_int else 0
    | false -> 0

  (* Check if we meet the conditions for placing a short for one of our symbols. *)
  (* If not, return the state unchanged, except we are now listening. *)
  let place_buy ~(state : state) =
    let ( let* ) = Result.( let* ) in
    let short_opt = consider_buying ~state ~qty:(qty state 1.0) in
    let possibilities =
      List.filter_map short_opt Backend.symbols
      |> List.sort (Ord.opp @@ fun (_, x) (_, y) -> Float.compare x y)
    in
    (* Eio.traceln "%a" (List.pp Float.pp) (List.map snd possibilities); *)
    let random_drop =
      match Backend.Input.options.dropout with
      | true ->
          (* Eio.traceln "buylow: %d possibilities, selecting one randomly" *)
          (* (List.length possibilities); *)
          List.filter_map
            (fun x -> if Util.coin_flip () then Some x else None)
            possibilities
      | false ->
          (* Eio.traceln "buylow: %d possibilities, selecting first" *)
          (* (List.length possibilities); *)
          possibilities
    in
    let choice = List.head_opt random_drop in
    let* state =
      match choice with
      | None -> Ok state
      | Some (order, _) ->
          let* state = Backend.place_order state order in
          Result.return @@ { state with content = DT_Status.Placed (0, order) }
    in
    Result.return @@ { state with State.current = Listening }

  let exit_position ~(state : state) time_held (buying_order : Order.t) =
    let ( let* ) = Result.( let* ) in
    let* current_bar = Bars.Latest.get state.latest buying_order.symbol in
    let current_price = State.price state buying_order.symbol in
    let timestamp = Item.timestamp current_bar in
    let price_difference = buying_order.price -. current_price in
    let cover_reason =
      Conditions.Sell_reason.make ~time_held ~state ~current_price ~buying_order
        ~price_difference
    in
    match cover_reason with
    | Profited _ | HoldingPeriod _ | StopLoss _ | FSO_High _ ->
        let profit =
          Float.of_int buying_order.qty *. (current_price -. buying_order.price)
        in
        let reason =
          Format.asprintf "Exiting because of %a. Profit: %f"
            Conditions.Sell_reason.pp cover_reason profit
          :: buying_order.reason
        in
        (* Eio.traceln "@[Profit from covering: %f@]@." profit; *)
        let* state =
          Backend.place_order state
          @@ Order.make ~symbol:buying_order.symbol ~side:Side.Sell
               ~tick:state.tick ~tif:buying_order.tif
               ~order_type:buying_order.order_type ~qty:buying_order.qty
               ~price:current_price ~timestamp ~reason ~profit:(Some profit)
        in
        Result.return
        @@ { state with State.current = Listening; content = DT_Status.Waiting }
    | Hold ->
        (* Eio.traceln "@[Holding...@]@."; *)
        Result.return
        @@ {
             state with
             State.current = Listening;
             content = DT_Status.Placed (time_held + 1, buying_order);
           }
    | HoldBelowBollinger ->
        Eio.traceln
          "Resetting hold time because we dipped below bollinger band.";
        Result.return
        @@ {
             state with
             State.current = Listening;
             content = DT_Status.Placed (0, buying_order);
           }

  let step (state : state) =
    let current = state.current in
    (* Eio.traceln "@[buylowbollinger: %a@]@." State.pp_state current; *)
    match current with
    | Ordering -> (
        (* Eio.traceln "@[%a@]@." DT_Status.pp state.content; *)
        match state.content with
        | Waiting -> place_buy ~state
        | Placed (time_held, order) -> exit_position ~state time_held order)
    | _ -> SU.handle_nonlogical_state state

  let run () = SU.run ~init_state step
end
