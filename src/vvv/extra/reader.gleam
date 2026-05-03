import gleam/function
import gleam/list
import vvv/extra

pub opaque type Reader(v, ctx) {
  Reader(run: fn(ctx) -> v)
}

pub fn run(reader reader: Reader(v, ctx), context ctx: ctx) -> v {
  reader.run(ctx)
}

pub const ask = Reader(function.identity)

pub fn asks(fun: fn(ctx) -> v) -> Reader(v, ctx) {
  map(ask, fun)
}

pub fn local(reader: Reader(v, b), fun: fn(a) -> b) -> Reader(v, a) {
  use ctx <- map(ask)
  reader.run(fun(ctx))
}

pub fn return(value: v) -> Reader(v, ctx) {
  use _ <- Reader
  value
}

pub fn bind(
  reader: Reader(a, ctx),
  then: fn(a) -> Reader(b, ctx),
) -> Reader(b, ctx) {
  use ctx <- Reader
  then(reader.run(ctx)).run(ctx)
}

pub fn do(
  with reader: Reader(a, ctx),
  then then: fn() -> Reader(b, ctx),
) -> Reader(b, ctx) {
  use _ <- bind(reader)
  then()
}

pub fn try(
  reader: Reader(Result(a, err), ctx),
  then: fn(a) -> Reader(Result(b, err), ctx),
) -> Reader(Result(b, err), ctx) {
  use ctx <- Reader
  case reader.run(ctx) {
    Error(error) -> Error(error)
    Ok(value) -> then(value).run(ctx)
  }
}

pub fn map(reader: Reader(a, ctx), mapper: fn(a) -> b) -> Reader(b, ctx) {
  use ctx <- Reader
  mapper(reader.run(ctx))
}

pub fn map2(
  reader1: Reader(a, ctx),
  reader2: Reader(b, ctx),
  mapper: fn(a, b) -> c,
) -> Reader(c, ctx) {
  use ctx <- Reader
  mapper(reader1.run(ctx), reader2.run(ctx))
}

pub fn sequence(readers: List(Reader(v, ctx))) -> Reader(List(v), ctx) {
  use <- extra.return(map(_, list.reverse))
  use list, reader <- list.fold(readers, return([]))
  map2(list, reader, list.prepend)
}
