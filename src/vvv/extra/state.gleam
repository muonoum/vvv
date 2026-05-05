pub type State(v, ctx) {
  State(run: fn(ctx) -> #(v, ctx))
}

pub fn run(state state: State(v, ctx), context ctx: ctx) -> #(v, ctx) {
  state.run(ctx)
}

pub fn evaluate(state state: State(v, ctx), context ctx: ctx) -> v {
  state.run(ctx).0
}

pub fn execute(state state: State(v, ctx), context ctx: ctx) -> ctx {
  state.run(ctx).1
}

pub fn return(v: v) -> State(v, ctx) {
  use ctx <- State
  #(v, ctx)
}

pub fn bind(
  state: State(a, ctx),
  then: fn(a) -> State(b, ctx),
) -> State(b, ctx) {
  use ctx <- State
  let #(v, ctx) = state.run(ctx)
  then(v).run(ctx)
}

pub fn do(state: State(a, ctx), then: fn() -> State(b, ctx)) -> State(b, ctx) {
  use _ <- bind(state)
  then()
}

pub fn get() -> State(ctx, ctx) {
  use ctx <- State
  #(ctx, ctx)
}

pub fn put(ctx: ctx) -> State(Nil, ctx) {
  use _ctx <- State
  #(Nil, ctx)
}

pub fn map(state: State(a, ctx), mapper: fn(a) -> b) -> State(b, ctx) {
  use ctx <- State
  let #(v, ctx) = state.run(ctx)
  #(mapper(v), ctx)
}

pub fn update(mapper: fn(ctx) -> ctx) -> State(Nil, ctx) {
  use ctx <- bind(get())
  put(mapper(ctx))
}
