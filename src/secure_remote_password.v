module firebird

import arrays
import crypto.rand
import crypto.sha1
import crypto.sha256
import encoding.hex
import hash
import math.big

// http://srp.stanford.edu/design.html

const srp_key_size = 128
const srp_salt_size = 32
const big_integer_max = big.integer_from_int(1).left_shift(128) // 1 << 128

// https://github.com/FirebirdSQL/firebird/blob/v5.0-release/src/auth/SecureRemotePassword/srp.cpp#L14
const big_prime_bytes = hex.decode('E67D2E994B2F900C3F41F08F5BB2627ED0D49EE1FE767A52EFCD565CD6E768812C3E1E9CE8F0A8BEA6CB13CD29DDEBF7A96D4A93B55D488DF099A15C89DCB0640738EB2CBDD9A8F7BAB561AB1B0DC1C6CDABF303264A08D1BCA932D1F1EE428B619D970F342ABA9A65793B8B2F041AE5364350C16F735F56ECBCA87BD57B29E7') or {
	panic(err) // should never panic
}

// https://github.com/FirebirdSQL/firebird/blob/v5.0-release/src/auth/SecureRemotePassword/srp.cpp#L19
const generator_int = 2

// https://github.com/FirebirdSQL/firebird/blob/v5.0-release/src/auth/SecureRemotePassword/srp.cpp#L32
const multiplier_string = '1277432915985975349439481660349303019122249720001'

fn get_prime() (big.Integer, big.Integer, big.Integer) {
	prime := big.integer_from_bytes(big_prime_bytes)
	g := big.integer_from_int(generator_int)
	k := big.integer_from_string(multiplier_string) or { panic(err) } // should never panic
	return prime, g, k
}

fn pad(v big.Integer) []u8 {
	mut buf := []u8{}
	mut n := big.integer_from_i64(0) + v

	for i := 0; i < srp_key_size; i++ {
		buf = arrays.concat(buf, u8(big.integer_from_i64(255).bitwise_and(n).int()))
		n = n / big.integer_from_i64(256)
	}

	// swap u8 positions
	for i := 0; i < srp_key_size; i++ {
		j := srp_key_size - 1 - i
		i_value := buf[i]
		j_value := buf[j]
		buf[i] = j_value
		buf[j] = i_value
	}

	get_first_non_zero_index := fn [buf] () int {
		len := buf.len
		for i := 0; i < len; i++ {
			if buf[i] != 0 {
				return i
			}
		}
		return len - 1
	}

	first_non_zero_index := get_first_non_zero_index()
	return buf[first_non_zero_index..]
}

fn get_scramble(client_public_key big.Integer, server_public_key big.Integer) big.Integer {
	// client_public_key:A client public ephemeral values
	// server_public_key:B server public ephemeral values
	mut digest := sha1.new()
	digest.write(pad(client_public_key)) or { panic(err) }
	digest.write(pad(server_public_key)) or { panic(err) }
	return big.integer_from_bytes(digest.sum([]u8{}))
}

fn get_client_seed() (big.Integer, big.Integer) {
	prime, g, _ := get_prime()
	client_secret_key := rand.int_big(big_integer_max) or { panic(err) }
	client_public_key := g.big_mod_pow(client_secret_key, prime) or { panic(err) }
	return client_public_key, client_secret_key
}

fn get_salt() []u8 {
	if is_debug() {
		return []u8{}
	}
	return rand.read(srp_salt_size) or { panic(err) }
}

fn get_verifier(user string, password string, salt []u8) big.Integer {
	prime, g, _ := get_prime()
	x := get_user_hash(salt, user, password)
	verifier := g.big_mod_pow(x, prime) or { panic(err) }
	return verifier
}

fn get_server_seed(v big.Integer) (big.Integer, big.Integer) {
	prime, g, k := get_prime()
	server_secret_key := rand.int_big(big_integer_max) or { panic(err) }
	gb := g.big_mod_pow(server_secret_key, prime) or { panic(err) } // gb = pow(g, b, N)
	kv := (k * v) % prime // kv = (k * v) % N
	server_public_key := (kv + gb) % prime // B = (kv + gb) % N
	return server_public_key, server_secret_key
}

fn get_string_hash(s string) big.Integer {
	mut digest := sha1.new()
	digest.write(s.bytes()) or { panic(err) }
	return big.integer_from_bytes(digest.sum([]u8{}))
}

fn get_user_hash(salt []u8, user string, password string) big.Integer {
	mut hash1 := sha1.new()
	hash1.write('${user}:${password}'.bytes()) or {}
	mut hash2 := sha1.new()
	hash2.write(salt) or {}
	hash2.write(hash1.sum([]u8{})) or {}
	return big.integer_from_bytes(hash2.sum([]u8{}))
}

fn get_client_session(user string, password string, salt []u8, client_public_key big.Integer, server_public_key big.Integer, client_secret_key big.Integer) []u8 {
	prime, g, k := get_prime()
	u := get_scramble(client_public_key, server_public_key)
	x := get_user_hash(salt, user, password)
	gx := g.big_mod_pow(x, prime) or { panic(err) } // gx = pow(g, x, N)
	kgx := (k * gx) % prime // kgx = (k * gx) % N
	diff := (server_public_key - kgx) % prime // diff = (B - kgx) % N
	ux := (u * x) % prime // ux = (u * x) % N
	aux := (client_secret_key + ux) % prime // aux = (a+ ux) % N
	session_secret := diff.big_mod_pow(aux, prime) or { panic(err) } // (B - kg^x) ^ (a+ ux)
	return big_int_to_sha1(session_secret)
}

fn get_server_session(user string, password string, salt []u8, client_public_key big.Integer, server_public_key big.Integer, server_secret_key big.Integer) []u8 {
	prime, _, _ := get_prime()
	u := get_scramble(client_public_key, server_public_key)
	v := get_verifier(user, password, salt)
	vu := v.big_mod_pow(u, prime) or { panic(err) }
	avu := (client_public_key * vu) % prime
	session_secret := avu.big_mod_pow(server_secret_key, prime) or { panic(err) }
	return big_int_to_sha1(session_secret)
}

fn get_client_proof(user string, password string, salt []u8, client_public_key big.Integer, server_public_key big.Integer, client_secret_key big.Integer, plugin_name string) ([]u8, []u8) {
	// M = H(H(N) xor H(g), H(I), s, A, B, K)
	prime, g, _ := get_prime()
	key_k := get_client_session(user, password, salt, client_public_key, server_public_key,
		client_secret_key)

	n1 := big.integer_from_bytes(big_int_to_sha1(prime))
	n2 := big.integer_from_bytes(big_int_to_sha1(g))
	n3 := n1.big_mod_pow(n2, prime) or { panic(err) }
	n4 := get_string_hash(user)

	new_digest := fn [plugin_name] () hash.Hash {
		if plugin_name == 'Srp' {
			return sha1.new()
		}

		if plugin_name == 'Srp256' {
			return sha256.new()
		}

		err := format_error_message('Secure Remote Password error: unsupported plugin name')
		panic(err)
	}

	mut digest := new_digest()
	digest.write(big_integer_to_byte_array(n3)) or {}
	digest.write(big_integer_to_byte_array(n4)) or {}
	digest.write(salt) or {}
	digest.write(big_integer_to_byte_array(client_public_key)) or {}
	digest.write(big_integer_to_byte_array(client_public_key)) or {}
	digest.write(key_k) or {}
	key_m := digest.sum([]u8{})

	return key_m, key_k
}
