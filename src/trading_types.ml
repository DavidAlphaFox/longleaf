module TimeInForce = struct
  type t =
    | Day
    | GoodTillCanceled
    | Opening
    | Close
    | ImmediateOrCancel
    | FillOrKill

  let to_string = function
    | Day -> "day"
    | GoodTillCanceled -> "gtc"
    | Opening -> "opg"
    | Close -> "cls"
    | ImmediateOrCancel -> "ioc"
    | FillOrKill -> "fok"
end

module Side = struct
  type t = Buy | Sell

  let to_string = function Buy -> "buy" | Sell -> "sell"
end

module OrderType = struct
  type t = Market | Limit | Stop | StopLimit | TrailingStop

  let to_string = function
    | Market -> "market"
    | Limit -> "limit"
    | Stop -> "stop"
    | StopLimit -> "stop_limit"
    | TrailingStop -> "trailing_stop"
end
