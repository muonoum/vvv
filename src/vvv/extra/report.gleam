pub opaque type Report(issue) {
  Report(issue: issue, context: List(issue))
}

pub fn new(issue: issue) -> Report(issue) {
  Report(issue:, context: [])
}

pub fn issue(report: Report(issue)) -> issue {
  report.issue
}

pub fn get_context(report: Report(issue)) -> List(issue) {
  report.context
}

pub fn error(issue: issue) -> Result(success, Report(issue)) {
  Error(new(issue))
}

pub fn context(report: Report(issue), issue: issue) -> Report(issue) {
  Report(issue:, context: [report.issue, ..report.context])
}

pub fn error_context(
  result: Result(value, Report(issue)),
  issue: issue,
) -> Result(value, Report(issue)) {
  case result {
    Ok(_) -> result
    Error(report) -> Error(context(report, issue))
  }
}

pub fn map_error(
  result: Result(value, error),
  map: fn(error) -> issue,
) -> Result(value, Report(issue)) {
  case result {
    Ok(value) -> Ok(value)
    Error(err) -> error(map(err))
  }
}

pub fn replace_error(
  result: Result(value, _),
  issue: issue,
) -> Result(value, Report(issue)) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> error(issue)
  }
}
