#!/usr/bin/env ruby
# frozen_string_literal: true
# Registers the App Store bundle IDs and makes sure this Mac can sign with an
# Apple Distribution certificate. Reads ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_P8.
# Writes a shell env file. Does not print the key, the token, or the team id.

require "openssl"
require "json"
require "net/http"
require "base64"
require "fileutils"
require "securerandom"
require "time"

API = "https://api.appstoreconnect.apple.com".freeze

BUNDLES = [
  ["com.ouijabored66.lumenvoice", "Lumen Voice", "IOS"],
  ["com.ouijabored66.lumenvoice.watchkitapp", "Lumen Voice Watch", "WATCH_OS"],
  ["com.ouijabored66.lumenvoice.controls", "Lumen Voice Controls", "IOS"],
  ["com.ouijabored66.lumenvoice.watchkitapp.talkface", "Lumen Voice Watch Face", "WATCH_OS"],
].freeze

def die(message)
  warn message
  exit 1
end

def b64url(data)
  Base64.urlsafe_encode64(data).delete("=")
end

def ecdsa_raw(der)
  seq = OpenSSL::ASN1.decode(der)
  parts = seq.value.map do |item|
    bytes = item.value.to_s(2)
    bytes = bytes[-32, 32] if bytes.bytesize > 32
    bytes.rjust(32, "\x00")
  end
  die("Could not sign the App Store Connect request.") unless parts.size == 2
  parts.join
end

def jwt(key_id, issuer, p8)
  key = OpenSSL::PKey.read(p8)
  now = Time.now.to_i
  header = b64url({ alg: "ES256", kid: key_id, typ: "JWT" }.to_json)
  body = b64url({ iss: issuer, iat: now, exp: now + 1000, aud: "appstoreconnect-v1" }.to_json)
  signing_input = "#{header}.#{body}"
  sig = ecdsa_raw(key.sign(OpenSSL::Digest::SHA256.new, signing_input))
  "#{signing_input}.#{b64url(sig)}"
end

def call_api(method, path, token, body = nil, query = nil)
  uri = URI(API + path)
  uri.query = URI.encode_www_form(query) if query
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  request = method == "POST" ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(body) if body
  response = http.request(request)
  parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
  [response.code.to_i, parsed]
rescue JSON::ParserError
  [response.code.to_i, {}]
end

def error_detail(parsed)
  parsed.dig("errors", 0, "detail") || "The App Store Connect request failed."
end

def ensure_bundle(token, identifier, name, platform)
  code, parsed = call_api("GET", "/v1/bundleIds", token, nil, { "filter[identifier]" => identifier })
  die("Could not list bundle IDs (#{code}). The API key needs Admin access.") unless code == 200
  return if parsed["data"].is_a?(Array) && !parsed["data"].empty?

  payload = {
    data: {
      type: "bundleIds",
      attributes: { identifier: identifier, name: name, platform: platform },
    },
  }
  code, parsed = call_api("POST", "/v1/bundleIds", token, payload)
  if code >= 400 && platform == "WATCH_OS"
    payload[:data][:attributes][:platform] = "IOS"
    code, parsed = call_api("POST", "/v1/bundleIds", token, payload)
  end
  return if code == 201 || code == 409

  die("Could not register #{identifier}. #{error_detail(parsed)}")
end

def team_from_der(der)
  cert = OpenSSL::X509::Certificate.new(der)
  cert.subject.to_a.each do |kind, value, _|
    return value if kind == "OU" && !value.to_s.empty?
  end
  nil
end

def distribution_certs(token)
  code, parsed = call_api("GET", "/v1/certificates", token, nil, { "limit" => "200" })
  die("Could not list certificates (#{code}). The API key needs Admin access.") unless code == 200
  (parsed["data"] || []).select do |item|
    kind = item.dig("attributes", "certificateType").to_s
    kind.include?("DISTRIBUTION") && !kind.include?("DEVELOPMENT") && !kind.include?("MAC_")
  end
end

def create_distribution_cert(token, work)
  key_path = File.join(work, "distribution.key")
  csr_path = File.join(work, "distribution.csr")
  ok = system(
    "openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
    "-keyout", key_path, "-out", csr_path,
    "-subj", "/CN=Lumen Voice Distribution"
  )
  die("Could not make a certificate request.") unless ok
  csr = File.read(csr_path)
  code, parsed = call_api("POST", "/v1/certificates", token, {
    data: {
      type: "certificates",
      attributes: { certificateType: "DISTRIBUTION", csrContent: csr },
    },
  })
  unless code == 201
    die(
      "Could not create an Apple Distribution certificate. #{error_detail(parsed)} " \
      "If the account already has as many as Apple allows, revoke an unused Apple Distribution certificate and run this again."
    )
  end
  der = Base64.decode64(parsed.dig("data", "attributes", "certificateContent").to_s)
  die("The new certificate was empty.") if der.empty?
  cer_path = File.join(work, "distribution.cer")
  File.binwrite(cer_path, der)
  [key_path, cer_path, team_from_der(der)]
end

def import_identity(key_path, cer_path, work)
  pem_path = File.join(work, "distribution.pem")
  p12_path = File.join(work, "distribution.p12")
  password = SecureRandom.hex(24)
  ok = system("openssl", "x509", "-inform", "DER", "-in", cer_path, "-out", pem_path)
  die("Could not read the new certificate.") unless ok
  ok = system(
    "openssl", "pkcs12", "-export",
    "-inkey", key_path, "-in", pem_path, "-out", p12_path,
    "-passout", "pass:#{password}"
  )
  die("Could not pack the signing identity.") unless ok
  keychain = File.join(work, "signing.keychain-db")
  ok = system("security", "create-keychain", "-p", password, keychain)
  die("Could not create a keychain.") unless ok
  system("security", "set-keychain-settings", "-lut", "21600", keychain)
  system("security", "unlock-keychain", "-p", password, keychain)
  current = `security list-keychains -d user`.split("\n").map { |line| line.strip.delete('"') }.reject(&:empty?)
  system("security", "list-keychains", "-d", "user", "-s", keychain, *current)
  system("security", "default-keychain", "-s", keychain)
  ok = system(
    "security", "import", p12_path, "-k", keychain, "-P", password,
    "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"
  )
  die("Could not import the signing identity.") unless ok
  system(
    "security", "set-key-partition-list",
    "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain
  )
  [keychain, password]
end

work = ARGV[0]
die("Pass a work directory.") if work.nil? || work.empty?
FileUtils.mkdir_p(work)

key_id = ENV["ASC_KEY_ID"].to_s
issuer = ENV["ASC_ISSUER_ID"].to_s
p8 = ENV["ASC_KEY_P8"].to_s
die("ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_P8 are required.") if key_id.empty? || issuer.empty? || p8.empty?

token = jwt(key_id, issuer, p8)
BUNDLES.each { |identifier, name, platform| ensure_bundle(token, identifier, name, platform) }

existing = distribution_certs(token)
team = nil
keychain = nil
keychain_password = nil
if existing.empty?
  _key, cer, team = create_distribution_cert(token, work)
  keychain, keychain_password = import_identity(File.join(work, "distribution.key"), cer, work)
else
  content = existing.first.dig("attributes", "certificateContent")
  team = team_from_der(Base64.decode64(content)) if content
  # A fresh runner does not have the private key for an older certificate.
  # Make one this run can sign with. Apple limits how many can exist at once.
  key_path, cer_path, created_team = create_distribution_cert(token, work)
  team = created_team if created_team
  keychain, keychain_password = import_identity(key_path, cer_path, work)
end
die("Could not read the team from the distribution certificate.") if team.nil? || team.empty?

lines = ["APPLE_TEAM_ID=#{team}"]
if keychain
  lines << "SIGNING_KEYCHAIN=#{keychain}"
  lines << "SIGNING_KEYCHAIN_PASSWORD=#{keychain_password}"
end
File.write(File.join(work, "env"), lines.join("\n") + "\n")
File.chmod(0o600, File.join(work, "env"))
warn "Bundle IDs are registered and a distribution certificate is ready."
