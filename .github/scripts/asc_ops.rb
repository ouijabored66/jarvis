#!/usr/bin/env ruby
# frozen_string_literal: true
# App Store Connect ops for Lumen Voice. Never prints keys, tokens, or review notes.

require "openssl"
require "json"
require "net/http"
require "base64"
require "time"
require "cgi"

API = "https://api.appstoreconnect.apple.com".freeze
APP_ID = "6836863521".freeze

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
  request = case method
            when "POST" then Net::HTTP::Post.new(uri)
            when "PATCH" then Net::HTTP::Patch.new(uri)
            when "DELETE" then Net::HTTP::Delete.new(uri)
            else Net::HTTP::Get.new(uri)
            end
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(body) if body
  response = http.request(request)
  parsed = if response.body.to_s.empty?
             {}
           else
             JSON.parse(response.body)
           end
  [response.code.to_i, parsed]
rescue JSON::ParserError
  [response.code.to_i, {}]
end

def error_detail(parsed)
  parsed.dig("errors", 0, "detail") || parsed.dig("errors", 0, "title") || "The App Store Connect request failed."
end

def token_from_env
  key_id = ENV["ASC_KEY_ID"].to_s
  issuer = ENV["ASC_ISSUER_ID"].to_s
  p8 = ENV["ASC_KEY_P8"].to_s
  die("ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_P8 are required.") if key_id.empty? || issuer.empty? || p8.empty?
  jwt(key_id, issuer, p8)
end

def expiry_time(item)
  raw = item.dig("attributes", "expirationDate").to_s
  Time.parse(raw) rescue Time.at(0)
end

def cmd_revoke(token, cert_id)
  die("Pass a certificate id.") if cert_id.nil? || cert_id.empty?
  code, parsed = call_api("GET", "/v1/certificates/#{cert_id}", token)
  die("Could not read certificate #{cert_id} (#{code}). #{error_detail(parsed)}") unless code == 200
  attrs = parsed.dig("data", "attributes") || {}
  kind = attrs["certificateType"].to_s
  name = attrs["name"].to_s
  serial = attrs["serialNumber"].to_s
  exp = attrs["expirationDate"].to_s
  if kind.include?("DEVELOPMENT") || kind == "IOS_DEVELOPMENT" || kind == "MAC_DEVELOPMENT"
    die("Refusing to revoke a development certificate (#{kind}).")
  end
  unless kind.include?("DISTRIBUTION")
    die("Refusing to revoke certificate type #{kind}.")
  end
  if kind.include?("MANAGED")
    die("Refusing to revoke a managed distribution certificate.")
  end
  del, del_parsed = call_api("DELETE", "/v1/certificates/#{cert_id}", token)
  unless [200, 204].include?(del)
    die("Could not revoke #{cert_id} (#{del}). #{error_detail(del_parsed)}")
  end
  puts "Revoked Apple Distribution certificate #{cert_id} (#{name}, type #{kind}, serial #{serial}, expires #{exp})."
end

def version_for(token, version_string)
  code, parsed = call_api("GET", "/v1/apps/#{APP_ID}/appStoreVersions", token, nil, {
    "filter[platform]" => "IOS",
    "filter[versionString]" => version_string,
    "limit" => "10",
  })
  die("Could not list versions (#{code}). #{error_detail(parsed)}") unless code == 200
  data = parsed["data"] || []
  die("No App Store version #{version_string} found.") if data.empty?
  data.first
end

def build_for(token, version, build_number)
  # Builds are filtered by CFBundleVersion, not marketing version.
  code, parsed = call_api("GET", "/v1/builds", token, nil, {
    "filter[app]" => APP_ID,
    "filter[version]" => build_number,
    "limit" => "20",
    "sort" => "-uploadedDate",
  })
  die("Could not list builds (#{code}). #{error_detail(parsed)}") unless code == 200
  builds = parsed["data"] || []
  # Prefer a build whose preReleaseVersion matches marketing version when included later.
  builds.find { |b| b.dig("attributes", "version").to_s == build_number } || builds.first
end

def cmd_status(token, version_string, build_number)
  ver = version_for(token, version_string)
  vattr = ver["attributes"] || {}
  puts "version #{version_string} id=#{ver['id']} state=#{vattr['appStoreState']} releaseType=#{vattr['releaseType']}"
  build = build_for(token, version_string, build_number)
  if build
    battr = build["attributes"] || {}
    puts "build #{build_number} id=#{build['id']} processing=#{battr['processingState']} expired=#{battr['expired']} uploaded=#{battr['uploadedDate']}"
  else
    puts "build #{build_number} not found"
  end
  code, parsed = call_api("GET", "/v1/reviewSubmissions", token, nil, {
    "filter[app]" => APP_ID,
    "limit" => "20",
  })
  if code == 200
    (parsed["data"] || []).each do |sub|
      st = sub.dig("attributes", "state").to_s
      plat = sub.dig("attributes", "platform").to_s
      puts "reviewSubmission #{sub['id']} state=#{st} platform=#{plat}"
    end
  else
    puts "reviewSubmissions list failed (#{code})"
  end
  # review detail notes presence only
  dcode, dparsed = call_api("GET", "/v1/appStoreVersions/#{ver['id']}/appStoreReviewDetail", token)
  if dcode == 200
    notes = dparsed.dig("data", "attributes", "notes").to_s
    puts "reviewDetail id=#{dparsed.dig('data', 'id')} notes_present=#{!notes.empty?} notes_chars=#{notes.length}"
  elsif dcode == 404
    puts "reviewDetail missing"
  else
    puts "reviewDetail read failed (#{dcode})"
  end
end

def cmd_wait_build(token, build_number, timeout_s)
  deadline = Time.now + timeout_s
  last = nil
  loop do
    build = build_for(token, "1.6.2", build_number)
    state = build ? build.dig("attributes", "processingState").to_s : "MISSING"
    last = state
    puts "build #{build_number} processing=#{state}"
    return build if state == "VALID"
    die("Build #{build_number} failed processing (#{state}).") if %w[FAILED INVALID REJECTED].include?(state)
    die("Timed out waiting for build #{build_number} to become VALID (last=#{state}).") if Time.now >= deadline
    sleep 30
  end
end

def cancel_review_submissions(token)
  code, parsed = call_api("GET", "/v1/reviewSubmissions", token, nil, {
    "filter[app]" => APP_ID,
    "limit" => "20",
  })
  die("Could not list review submissions (#{code}). #{error_detail(parsed)}") unless code == 200
  canceled = 0
  (parsed["data"] || []).each do |sub|
    st = sub.dig("attributes", "state").to_s
    next unless %w[READY_FOR_REVIEW WAITING_FOR_REVIEW UNRESOLVED_ISSUES].include?(st)
    # IN_REVIEW is not canceled here if Apple rejects it; try WAITING first.
    body = { data: { type: "reviewSubmissions", id: sub["id"], attributes: { canceled: true } } }
    pcode, presult = call_api("PATCH", "/v1/reviewSubmissions/#{sub['id']}", token, body)
    if pcode >= 400
      warn "Could not cancel reviewSubmission #{sub['id']} in state #{st} (#{pcode}). #{error_detail(presult)}"
    else
      puts "Canceled reviewSubmission #{sub['id']} (was #{st})."
      canceled += 1
    end
  end
  # Legacy path: version submissions
  ver = version_for(token, "1.6.2")
  scode, sparsed = call_api("GET", "/v1/appStoreVersions/#{ver['id']}/appStoreVersionSubmission", token)
  if scode == 200 && sparsed.dig("data", "id")
    sid = sparsed.dig("data", "id")
    dcode, dparsed = call_api("DELETE", "/v1/appStoreVersionSubmissions/#{sid}", token)
    if [200, 204].include?(dcode)
      puts "Deleted legacy appStoreVersionSubmission #{sid}."
      canceled += 1
    else
      warn "Legacy submission delete #{sid} (#{dcode}). #{error_detail(dparsed)}"
    end
  end
  canceled
end

def wait_editable(token, version_string, timeout_s)
  deadline = Time.now + timeout_s
  loop do
    ver = version_for(token, version_string)
    state = ver.dig("attributes", "appStoreState").to_s
    puts "version #{version_string} state=#{state}"
    return ver if %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED INVALID_BINARY].include?(state)
    die("Timed out waiting for #{version_string} to become editable (last=#{state}).") if Time.now >= deadline
    sleep 15
  end
end

def attach_build(token, version_id, build_id)
  body = { data: { type: "builds", id: build_id } }
  code, parsed = call_api("PATCH", "/v1/appStoreVersions/#{version_id}/relationships/build", token, body)
  die("Could not attach build (#{code}). #{error_detail(parsed)}") unless [200, 204].include?(code)
  puts "Attached build #{build_id} to version #{version_id}."
end

def cmd_withdraw_and_attach(token, version_string, build_number)
  build = cmd_wait_build(token, build_number, 45 * 60)
  die("Build #{build_number} is not VALID.") unless build.dig("attributes", "processingState") == "VALID"
  cancel_review_submissions(token)
  ver = wait_editable(token, version_string, 10 * 60)
  attach_build(token, ver["id"], build["id"])
  cmd_status(token, version_string, build_number)
end

PLACEHOLDER = "Screen recording: <link to be added>"
SETUP_MARKER = "Settings > Custom > Cloud URL"

def desired_notes(existing, incoming)
  existing = existing.to_s
  incoming = incoming.to_s.strip
  die("Review notes body was empty.") if incoming.empty?
  # Never log incoming. Decide whether to write.
  has_setup = existing.include?(SETUP_MARKER) || existing.include?("pikadesktop.tail35f686.ts.net")
  has_placeholder = existing.include?("Screen recording:")
  if has_setup && has_placeholder
    return nil # already complete
  end
  body = if has_setup
           existing
         else
           incoming
         end
  unless body.include?("Screen recording:")
    body = PLACEHOLDER + "\n\n" + body.sub(/\A\s+/, "")
  end
  body
end

def cmd_update_notes(token, version_string, notes_body)
  ver = version_for(token, version_string)
  dcode, dparsed = call_api("GET", "/v1/appStoreVersions/#{ver['id']}/appStoreReviewDetail", token)
  if dcode == 404 || dparsed.dig("data", "id").nil?
    # Create review detail with notes
    body = {
      data: {
        type: "appStoreReviewDetails",
        attributes: { notes: notes_body },
        relationships: {
          appStoreVersion: { data: { type: "appStoreVersions", id: ver["id"] } },
        },
      },
    }
    ccode, cparsed = call_api("POST", "/v1/appStoreReviewDetails", token, body)
    die("Could not create review details (#{ccode}). #{error_detail(cparsed)}") unless [200, 201].include?(ccode)
    puts "Created App Review Information notes (#{notes_body.length} chars)."
    return
  end
  die("Could not read review details (#{dcode}). #{error_detail(dparsed)}") unless dcode == 200
  detail_id = dparsed.dig("data", "id")
  existing = dparsed.dig("data", "attributes", "notes").to_s
  updated = desired_notes(existing, notes_body)
  if updated.nil?
    puts "App Review Information notes already have the setup text and a screen-recording placeholder; left unchanged (#{existing.length} chars)."
    return
  end
  body = {
    data: {
      type: "appStoreReviewDetails",
      id: detail_id,
      attributes: { notes: updated },
    },
  }
  pcode, presult = call_api("PATCH", "/v1/appStoreReviewDetails/#{detail_id}", token, body)
  die("Could not update review notes (#{pcode}). #{error_detail(presult)}") unless [200, 204].include?(pcode)
  puts "Updated App Review Information notes (#{updated.length} chars). Token not printed."
end

cmd = ARGV[0].to_s
token = token_from_env
case cmd
when "revoke"
  cmd_revoke(token, ARGV[1].to_s)
when "status"
  cmd_status(token, ARGV[1].to_s.empty? ? "1.6.2" : ARGV[1], ARGV[2].to_s.empty? ? "5" : ARGV[2])
when "wait-build"
  cmd_wait_build(token, ARGV[1].to_s.empty? ? "5" : ARGV[1], (ARGV[2] || "2700").to_i)
when "withdraw-and-attach"
  cmd_withdraw_and_attach(token, ARGV[1].to_s.empty? ? "1.6.2" : ARGV[1], ARGV[2].to_s.empty? ? "5" : ARGV[2])
when "update-notes"
  notes = ENV["REVIEW_NOTES_BODY"].to_s
  die("REVIEW_NOTES_BODY is required.") if notes.empty?
  cmd_update_notes(token, ARGV[1].to_s.empty? ? "1.6.2" : ARGV[1], notes)
else
  die("Unknown command #{cmd}")
end
