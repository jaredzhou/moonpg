///|
/// SCRAM-SHA-256 authentication helpers.
///
/// Implements the client side of RFC 5802 / RFC 7677.

///|
/// Base64-encode with padding (for proof — PG's decoder requires it).
fn b64_encode_padded(data : BytesView) -> String {
  let buf = StringBuilder::new()
  let enc = @base64.Encoder::new()
  enc.encode_to(data, fn(ch) { buf.write_char(ch) }, padding=true)
  buf.to_string()
}

///|
/// Base64-encode without padding (for nonces — SCRAM convention).
fn b64_encode_raw(data : BytesView) -> String {
  let buf = StringBuilder::new()
  let enc = @base64.Encoder::new()
  enc.encode_to(data, fn(ch) { buf.write_char(ch) }, padding=false)
  buf.to_string()
}

///|
/// Base64-decode, SCRAM-safe (handles padding).
fn b64_decode(s : String) -> Bytes raise WireError {
  @base64.decode(s) catch {
    _ => raise WireError::InvalidMessage("base64 decode failed")
  }
}

///|
// ---------------------------------------------------------------------------
// PBKDF2-HMAC-SHA256
// ---------------------------------------------------------------------------

///|
/// XOR two fixed-size byte arrays element-wise.
fn xor_bytes(a : FixedArray[Byte], b : FixedArray[Byte]) -> FixedArray[Byte] {
  let len = a.length()
  let result = FixedArray::make(len, b'\x00')
  for i = 0; i < len; i = i + 1 {
    result[i] = (a[i].to_int() ^ b[i].to_int()).to_byte()
  }
  result
}

///|
fn as_bytesview(fa : FixedArray[Byte]) -> BytesView {
  fa.unsafe_reinterpret_as_bytes()
}

///|
/// PBKDF2-HMAC-SHA256.
fn pbkdf2_hmac_sha256(
  password : FixedArray[Byte],
  salt : Bytes,
  c : Int,
  dk_len : Int,
) -> FixedArray[Byte] {
  let h_len = 32
  let blocks = (dk_len + h_len - 1) / h_len
  let result = BytesMut::new()

  for block = 1; block <= blocks; block = block + 1 {
    let salted = BytesMut::new()
    salted.append_bytes(salt)
    salted.append_int_be(block)

    let u1 = @crypto.hmac(
      @crypto.SHA256::new(),
      as_bytesview(password),
      salted.to_bytes(),
    )
    let mut t = u1
    let mut u_prev = u1

    for i = 2; i <= c; i = i + 1 {
      let u_next = @crypto.hmac(
        @crypto.SHA256::new(),
        as_bytesview(password),
        as_bytesview(u_prev),
      )
      t = xor_bytes(t, u_next)
      u_prev = u_next
    }

    for i = 0; i < h_len; i = i + 1 {
      result.append_byte(t[i])
    }
  }

  result.to_bytes()[0:dk_len].to_owned().to_fixedarray()
}

///|
// ---------------------------------------------------------------------------
// Nonce generation
// ---------------------------------------------------------------------------

///|
let nonce_counter : Ref[Int] = Ref(0)

///|
fn generate_nonce() -> String {
  nonce_counter.val = nonce_counter.val + 1
  let buf = BytesMut::new()
  buf.append_int_be(nonce_counter.val)
  let hash = @crypto.sha256(buf.to_bytes())
  b64_encode_raw(hash.unsafe_reinterpret_as_bytes()[0:18])
}

///|
// ---------------------------------------------------------------------------
// SCRAM client message parsing
// ---------------------------------------------------------------------------

///|
fn parse_scram_attrs(
  msg : String,
) -> @hashmap.HashMap[String, String] raise WireError {
  let map : @hashmap.HashMap[String, String] = @hashmap.HashMap([])
  let bytes = @utf8.encode(msg)
  let mut i = 0
  let len = bytes.length()
  while i < len {
    let key = bytes[i:i + 1].to_owned().to_unchecked_string()
    i = i + 1
    guard i < len && bytes[i] == b'=' else {
      raise WireError::InvalidMessage(
        "parse_scram_attrs: expected '=' after key",
      )
    }
    i = i + 1
    let start = i
    while i < len && bytes[i] != b',' {
      i = i + 1
    }
    let value = @utf8.decode(bytes[start:i].to_owned()) catch {
      _ => bytes[start:i].to_owned().to_unchecked_string()
    }
    map.set(key, value)
    if i < len {
      i = i + 1
    }
  }
  map
}

///|
// ---------------------------------------------------------------------------
// SCRAM-SHA-256 exchange state
// ---------------------------------------------------------------------------

///|
priv struct ScramState {
  client_nonce : String
  client_first_message_bare : String
  salted_password : FixedArray[Byte]
  auth_message : String
}

///|
fn scram_client_first(
  user : String,
) -> (SASLInitialResponse, ScramState) {
  let client_nonce = generate_nonce()
  let client_first_bare = "n=\{user},r=\{client_nonce}"
  let client_first = "n,,\{client_first_bare}"
  let msg = SASLInitialResponse::{
    mechanism: "SCRAM-SHA-256",
    initial_response: @utf8.encode(client_first),
  }
  let state = ScramState::{
    client_nonce,
    client_first_message_bare: client_first_bare,
    salted_password: FixedArray::make(32, b'\x00'),
    auth_message: "",
  }
  (msg, state)
}

///|
fn scram_client_final(
  password : String,
  server_first_msg : String,
  state : ScramState,
) -> (SASLResponse, ScramState) raise WireError {
  let attrs = parse_scram_attrs(server_first_msg)

  let combined_nonce = match attrs.get("r") {
    Some(r) => r
    None =>
      raise WireError::InvalidMessage("SCRAM: server-first missing r= (nonce)")
  }
  let prefix = state.client_nonce
  guard combined_nonce.length() >= prefix.length() &&
    combined_nonce[0:prefix.length()] == prefix else {
    raise WireError::InvalidMessage(
      "SCRAM: server nonce does not start with client nonce",
    )
  }

  let salt_b64 = match attrs.get("s") {
    Some(s) => s
    None =>
      raise WireError::InvalidMessage("SCRAM: server-first missing s= (salt)")
  }
  let iterations_s = match attrs.get("i") {
    Some(i) => i
    None =>
      raise WireError::InvalidMessage(
        "SCRAM: server-first missing i= (iterations)",
      )
  }
  let iterations = @string.parse_int(iterations_s) catch {
    _ =>
      raise WireError::InvalidMessage(
        "SCRAM: invalid iteration count: \{iterations_s}",
      )
  }

  let salt = b64_decode(salt_b64)
  let pw_fa = @utf8.encode(password).to_fixedarray()

  // 1. SaltedPassword = PBKDF2(HMAC-SHA-256, password, salt, iterations, 32)
  let salted_password = pbkdf2_hmac_sha256(pw_fa, salt, iterations, 32)

  // 2. ClientKey = HMAC(SaltedPassword, "Client Key")
  let client_key = @crypto.hmac(
    @crypto.SHA256::new(),
    as_bytesview(salted_password),
    b"Client Key",
  )

  // 3. StoredKey = SHA256(ClientKey)
  let stored_key = @crypto.sha256(client_key)

  // 4. AuthMessage
  let client_final_without_proof = "c=biws,r=\{combined_nonce}"
  let auth_message = "\{state.client_first_message_bare},\{server_first_msg},\{client_final_without_proof}"

  // 5. ClientSignature = HMAC(StoredKey, AuthMessage)
  let client_signature = @crypto.hmac(
    @crypto.SHA256::new(),
    as_bytesview(stored_key),
    @utf8.encode(auth_message),
  )

  // 6. ClientProof = ClientKey XOR ClientSignature
  let client_proof = xor_bytes(client_key, client_signature)
  let proof_b64 = b64_encode_padded(client_proof.unsafe_reinterpret_as_bytes())

  let client_final = "\{client_final_without_proof},p=\{proof_b64}"

  let msg = SASLResponse::{ data: @utf8.encode(client_final) }
  let new_state = ScramState::{
    client_nonce: state.client_nonce,
    client_first_message_bare: state.client_first_message_bare,
    salted_password,
    auth_message,
  }
  (msg, new_state)
}

///|
fn scram_verify_server_final(
  server_final_msg : String,
  state : ScramState,
) -> Unit raise WireError {
  let attrs = parse_scram_attrs(server_final_msg)

  match attrs.get("e") {
    Some(e) => raise WireError::InvalidMessage("SCRAM: server error: \{e}")
    None => ()
  }

  let server_proof_b64 = match attrs.get("v") {
    Some(v) => v
    None =>
      raise WireError::InvalidMessage(
        "SCRAM: server-final missing v= (signature)",
      )
  }

  // ServerKey = HMAC(SaltedPassword, "Server Key")
  let server_key = @crypto.hmac(
    @crypto.SHA256::new(),
    as_bytesview(state.salted_password),
    b"Server Key",
  )

  // ServerSignature = HMAC(ServerKey, AuthMessage)
  let expected_sig = @crypto.hmac(
    @crypto.SHA256::new(),
    as_bytesview(server_key),
    @utf8.encode(state.auth_message),
  )

  let expected_b64 = b64_encode_padded(
    expected_sig.unsafe_reinterpret_as_bytes(),
  )
  guard server_proof_b64 == expected_b64 else {
    raise WireError::InvalidMessage(
      "SCRAM: server signature verification failed",
    )
  }
}

///|
/// Validate SCRAM-SHA-256 availability and delegate to `handle_scram_auth`.
pub async fn handle_sasl_auth(
  conn : RawConn,
  user : String,
  mechanisms : Array[String],
  password : String?,
) -> Unit raise WireError {
  let mut has_scram = false
  for i = 0; i < mechanisms.length(); i = i + 1 {
    if mechanisms[i] == "SCRAM-SHA-256" {
      has_scram = true
      break
    }
  }
  guard has_scram else {
    let mech_list = mechanisms.join(", ")
    raise WireError::Auth(
      "server requires SASL but SCRAM-SHA-256 not available. Offered: \{mech_list}",
    )
  }
  match password {
    Some(pw) => handle_scram_auth(conn, user, pw)
    None =>
      raise WireError::Auth(
        "server requested SASL/SCRAM but no password provided",
      )
  }
}

///|
/// Run the full SCRAM-SHA-256 handshake.
pub async fn handle_scram_auth(
  conn : RawConn,
  user : String,
  password : String,
) -> Unit raise WireError {
  // 1. Build and send client-first-message
  let (init_msg, state) = scram_client_first(user)
  conn.send(init_msg)

  // 2. Receive server-first-message
  let msg1 = conn.receive()
  let server_first_data = match msg1 {
    AuthenticationSASLContinue(m) => m.data
    ErrorResponse(m) =>
      raise WireError::InvalidMessage(
        "SCRAM: server error: \{m.message().unwrap_or("unknown")}",
      )
    _ => raise WireError::InvalidMessage("SCRAM: expected SASLContinue")
  }
  let server_first_msg = @utf8.decode(server_first_data) catch {
    _ => server_first_data.to_unchecked_string()
  }

  // 3. Build and send client-final-message
  let (final_msg, state) = scram_client_final(password, server_first_msg, state)
  conn.send(final_msg)

  // 4. Receive server-final-message
  let msg2 = conn.receive()
  let server_final_data = match msg2 {
    AuthenticationSASLFinal(m) => m.data
    ErrorResponse(m) =>
      raise WireError::InvalidMessage(
        "SCRAM: server error: \{m.message().unwrap_or("unknown")}",
      )
    _ => raise WireError::InvalidMessage("SCRAM: expected SASLFinal")
  }
  let server_final_msg = @utf8.decode(server_final_data) catch {
    _ => server_final_data.to_unchecked_string()
  }
  // 5. Verify server signature
  scram_verify_server_final(server_final_msg, state)
}
