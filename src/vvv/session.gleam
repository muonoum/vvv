import vvv/oauth

pub type User {
  User(name: String, email: String, id_token: String, access_token: String)
}

pub type Session {
  LoginSession(oauth.State)
  UserSession(User)
}
