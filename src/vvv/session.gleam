pub type User {
  User(name: String, email: String, id_token: String, access_token: String)
}

pub type Session {
  LoginSession(Login)
  UserSession(User)
}

pub type Login {
  Login(nonce: String, code_verifier: String)
}
