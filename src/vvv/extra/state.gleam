pub opaque type State(v, ctx) {
  State(run: fn(ctx) -> #(v, ctx))
}

pub fn run(state state: State(v, ctx), context ctx: ctx) -> #(v, ctx) {
  state.run(ctx)
}

pub fn return(v: v) -> State(v, ctx) {
  use ctx <- State
  #(v, ctx)
}

pub fn bind(
  state: State(a, ctx),
  next: fn(a) -> State(b, ctx),
) -> State(b, ctx) {
  use ctx <- State
  let #(v, ctx) = state.run(ctx)
  next(v).run(ctx)
}

pub fn do(state: State(a, ctx), next: fn() -> State(b, ctx)) -> State(b, ctx) {
  use _ <- bind(state)
  next()
}

pub fn get() -> State(ctx, ctx) {
  use ctx <- State
  #(ctx, ctx)
}

pub fn put(ctx: ctx) -> State(Nil, ctx) {
  use _ctx <- State
  #(Nil, ctx)
}
