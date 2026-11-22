#!/usr/bin/env python3
"""App Store Connect helper for Virt's TestFlight workflow (copied from time2play-app's). Runs on a GitHub runner,
never prints a key.

  asc.py ready               checks the key works, registers the two App IDs if they're missing (the app and its
                             timer extension), turns on Sign in with Apple for the app's App ID if it's off (#578,
                             Training for friends), and checks the App Store Connect app exists
  asc.py signin              only the Sign in with Apple step
  asc.py signing OUTDIR      the App Store signing pieces: the distribution certificate and an App Store profile for
                             each bundle id
  asc.py wait BUILD          waits until build BUILD of version 1.0 is processed, then turns on internal testing
  asc.py status              lists the app's builds (number, state) for the log
  asc.py invite              sends the TestFlight invitation email again to the internal group's testers
  asc.py external            (#581, Tyler's go on 2026-11-22) the friends' external TestFlight: test information,
                             the "Friends" group with a public link, the newest processed build in it, and that build
                             sent to Beta App Review (TestFlight's review, not the App Store's)

Reads ASC_KEY_PATH (the .p8 file), ASC_KEY_ID and ASC_ISSUER_ID from the environment.

The distribution certificate's private key isn't stored anywhere. It's re-made on each run from the App Store Connect
key (a one-way hash of it seeds the generator), so every run gets the same key, finds the certificate Apple already
issued for it, and Apple's limit on distribution certificates is never reached. A new App Store Connect key makes one
new certificate, once. Virt uses the same App Store Connect key and the same seed as time2play-app, so both apps
share one distribution certificate.

It never submits anything for App Store review. `external` sends a build to Beta App Review only (#581).
"""
import base64, hashlib, hmac, json, os, sys, time, urllib.error, urllib.parse, urllib.request

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.tyleralocke.virt"
# every bundle id the build signs, with the name its App ID gets if it has to be registered
BUNDLES = {"com.tyleralocke.virt": "Virt", "com.tyleralocke.virt.timer": "Virt Timer"}
# entitlements a bundle's profile must carry; a profile without them (made before the capability) is replaced
NEEDS = {"com.tyleralocke.virt": [b"com.apple.developer.applesignin"]}
# the env names the workflow reads each profile's name from
PROFILE_ENV = {"com.tyleralocke.virt": "VIRT_PROFILE_NAME", "com.tyleralocke.virt.timer": "VIRT_TIMER_PROFILE_NAME"}
VERSION = "1.0"


def die(msg):
    print(f"::error::{msg}")
    sys.exit(1)


def key_text():
    with open(os.environ["ASC_KEY_PATH"], "rb") as f:
        return f.read()


def token():
    import jwt  # pyjwt
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
                      key_text(), algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method, path, body=None, ok_missing=False, tries=4):
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except (urllib.error.URLError, TimeoutError) as e:
        code = getattr(e, "code", None)
        # Apple's API has passing 5xx errors (a 500 on GET /v1/bundleIds, Nov 17): wait and try again, reads only
        if tries > 1 and method == "GET" and (code is None or code >= 500):
            print(f"App Store Connect: {code or 'no answer'} to {method} {urllib.parse.urlparse(url).path}; trying again")
            time.sleep(10 * (5 - tries))
            return call(method, path, body, ok_missing, tries - 1)
        if not isinstance(e, urllib.error.HTTPError):
            raise
        detail = e.read().decode(errors="replace")
        if ok_missing and e.code == 404:
            return None
        # Apple's errors name the problem (a missing permission says FORBIDDEN_ERROR); they never contain the key
        print(f"App Store Connect said {e.code} to {method} {urllib.parse.urlparse(url).path}:\n{detail}")
        raise SystemExit(2)


def q(params):
    return "?" + urllib.parse.urlencode(params)


def the_app():
    apps = call("GET", "/v1/apps" + q({"filter[bundleId]": BUNDLE_ID}))["data"]
    apps = [a for a in apps if a["attributes"]["bundleId"] == BUNDLE_ID]
    if not apps:
        die(f"No App Store Connect app with bundle id {BUNDLE_ID} (App Store Connect -> Apps -> + -> New App)")
    return apps[0]


# ---------- signing ----------

class Stream:
    """A deterministic byte stream from a secret seed (SHA-512 in counter mode)."""
    def __init__(self, seed):
        self.seed, self.n, self.buf = seed, 0, b""

    def __call__(self, k):
        while len(self.buf) < k:
            self.buf += hashlib.sha512(self.seed + self.n.to_bytes(8, "big")).digest()
            self.n += 1
        out, self.buf = self.buf[:k], self.buf[k:]
        return out


def distribution_key():
    from Crypto.PublicKey import RSA  # pycryptodome, pinned in the workflow so the same seed makes the same key
    seed = hmac.new(key_text(), b"time2play app store distribution key v1", hashlib.sha256).digest()
    return RSA.generate(2048, randfunc=Stream(seed))


def signing(outdir):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.x509.oid import NameOID

    os.makedirs(outdir, exist_ok=True)
    os.chmod(outdir, 0o700)
    rsa = distribution_key()
    pem = rsa.export_key(pkcs=8)
    key = serialization.load_pem_private_key(pem, password=None)
    n = key.public_key().public_numbers().n

    # the certificate Apple issued for this key, if there is one
    cert_id, cert_der = None, None
    for c in call("GET", "/v1/certificates" + q({"filter[certificateType]": "DISTRIBUTION", "limit": 200}))["data"]:
        der = base64.b64decode(c["attributes"]["certificateContent"])
        if x509.load_der_x509_certificate(der).public_key().public_numbers().n == n:
            cert_id, cert_der = c["id"], der
            break
    if cert_id:
        print(f"Distribution certificate: found ({cert_id})")
    else:
        csr = (x509.CertificateSigningRequestBuilder()
               .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Time2Play GitHub builds"),
                                        x509.NameAttribute(NameOID.COUNTRY_NAME, "US")]))
               .sign(key, hashes.SHA256()))
        csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
        made = call("POST", "/v1/certificates", {"data": {"type": "certificates", "attributes": {
            "certificateType": "DISTRIBUTION", "csrContent": csr_pem}}})["data"]
        cert_id, cert_der = made["id"], base64.b64decode(made["attributes"]["certificateContent"])
        print(f"Distribution certificate: made a new one ({cert_id})")

    # an App Store profile for each bundle id, with this certificate
    profiles = {b: profile_for(b, cert_id) for b in BUNDLES}

    # a .p12 the Mac's keychain accepts (its importer wants the older SHA-1 / 3DES packing), with a throwaway password
    from cryptography.hazmat.primitives.serialization import pkcs12
    import secrets
    password = secrets.token_hex(16).encode()
    enc = (serialization.PrivateFormat.PKCS12.encryption_builder().kdf_rounds(50000)
           .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC).hmac_hash(hashes.SHA1()).build(password))
    p12 = pkcs12.serialize_key_and_certificates(b"Virt distribution", key, x509.load_der_x509_certificate(cert_der), None, enc)
    with open(os.path.join(outdir, "dist.p12"), "wb") as f:
        f.write(p12)
    with open(os.path.join(outdir, "dist.p12.pass"), "wb") as f:
        f.write(password)
    with open(os.environ.get("GITHUB_ENV", os.devnull), "a") as env:
        for b, profile in profiles.items():
            with open(os.path.join(outdir, f"{b}.mobileprovision"), "wb") as f:
                f.write(base64.b64decode(profile["attributes"]["profileContent"]))
            env.write(f"{PROFILE_ENV[b]}={profile['attributes']['name']}\n")



# ---------- App IDs ----------

def bundle_id(identifier, register=True):
    """The App ID's App Store Connect id, registering it first if it's missing (its capabilities: sign_in_with_apple)."""
    found = call("GET", "/v1/bundleIds" + q({"filter[identifier]": identifier, "limit": 20}))["data"]
    found = [b for b in found if b["attributes"]["identifier"] == identifier]
    if found:
        print(f"App ID {identifier}: registered")
        return found[0]["id"]
    if not register:
        die(f"The App ID {identifier} isn't registered")
    made = call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": identifier, "name": BUNDLES.get(identifier, identifier.replace(".", " ")), "platform": "IOS"}}})["data"]
    print(f"App ID {identifier}: registered it now")
    return made["id"]


def profile_for(identifier, cert_id):
    bundle = bundle_id(identifier)
    caps = call("GET", f"/v1/bundleIds/{bundle}/bundleIdCapabilities")["data"]
    print(f"  capabilities: " + (", ".join(sorted(c["attributes"]["capabilityType"] for c in caps)) or "none"))
    name = f"{BUNDLES[identifier]} App Store {cert_id[:6]}"
    profile = None
    found = call("GET", "/v1/profiles" + q({"filter[name]": name, "filter[profileType]": "IOS_APP_STORE",
                                             "include": "certificates", "limit": 50}))
    for p in found["data"]:
        certs = [c["id"] for c in p["relationships"]["certificates"]["data"] or []]
        if p["attributes"]["profileState"] == "ACTIVE" and cert_id in certs and carries(p, identifier):
            profile = p
    if profile:
        print(f"  App Store profile: found ({name})")
        return profile
    if found["data"]:  # same name but out of date: a fresh one with a dated name
        name = f"{name} {time.strftime('%Y%m%d%H%M')}"
    profile = call("POST", "/v1/profiles", {"data": {"type": "profiles", "attributes": {
        "name": name, "profileType": "IOS_APP_STORE"}, "relationships": {
        "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
        "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})["data"]
    print(f"  App Store profile: made ({name})")
    return profile


def carries(profile, identifier):
    """True if the profile has every entitlement the bundle needs (the profile's text names each one)."""
    content = base64.b64decode(profile["attributes"].get("profileContent") or "")
    return all(e in content for e in NEEDS.get(identifier, []))


def sign_in_with_apple():
    """Training for friends (#578): Sign in with Apple on the app's App ID, as its own primary App ID. Turning it on
    makes the App ID's old profiles invalid; the next signing run makes fresh ones that carry it."""
    bundle = bundle_id(BUNDLE_ID)
    caps = [c["attributes"]["capabilityType"] for c in call("GET", f"/v1/bundleIds/{bundle}/bundleIdCapabilities")["data"]]
    if "APPLE_ID_AUTH" in caps:
        print("Sign in with Apple: already on the App ID")
        return
    call("POST", "/v1/bundleIdCapabilities", {"data": {"type": "bundleIdCapabilities", "attributes": {
        "capabilityType": "APPLE_ID_AUTH",
        "settings": [{"key": "APPLE_ID_AUTH_APP_CONSENT", "options": [{"key": "PRIMARY_APP_CONSENT"}]}]},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle}}}}})
    print("Sign in with Apple: turned on for the App ID")


def probe():
    """One read from each part of the API, with Apple's answer, so a failing check shows whether it's everything
    (Apple, or the key) or one endpoint."""
    for path in ["/v1/apps?limit=1", "/v1/bundleIds?limit=1", "/v1/bundleIds?filter[identifier]=com.tyleralocke.virt",
                 "/v1/certificates?limit=1", "/v1/profiles?limit=1", "/v1/users?limit=1", "/v1/builds?limit=1"]:
        req = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {token()}"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                print(f"probe {path}: {r.status}")
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")
            code = json.loads(body).get("errors", [{}])[0].get("code") if body.startswith("{") else ""
            print(f"probe {path}: {e.code} {code}")
        except Exception as e:  # no answer at all
            print(f"probe {path}: {type(e).__name__}")


def ready():
    for b in BUNDLES:
        bundle_id(b)
    sign_in_with_apple()
    app = the_app()
    print(f"App Store Connect app: {app['attributes']['name']} ({app['id']}), bundle id {app['attributes']['bundleId']}")
    print("READY")

# ---------- after the upload ----------

def builds(app_id, number=None):
    params = {"filter[app]": app_id, "sort": "-uploadedDate", "limit": 20, "fields[builds]": "version,processingState,uploadedDate,expired"}
    if number:
        params["filter[version]"] = number
    return call("GET", "/v1/builds" + q(params))["data"]


def status():
    app = the_app()
    print(f"App: {app['attributes']['name']} ({app['id']})")
    for b in builds(app["id"]):
        a = b["attributes"]
        print(f"  build {a['version']}: {a['processingState']} (uploaded {a['uploadedDate']})")


def internal_testing(app_id):
    # /v1/apps/{id}/betaGroups stopped listing the internal group on Nov 17 (time2play-app hit it); the filter works
    groups = call("GET", "/v1/betaGroups" + q({"filter[app]": app_id, "limit": 200,
                                                 "fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds"}))["data"]
    for g in groups:
        a = g["attributes"]
        print(f"Group: {a.get('name')} (internal: {a.get('isInternalGroup')}, every build: {a.get('hasAccessToAllBuilds')})")
    internal = [g for g in groups if g["attributes"].get("isInternalGroup")]
    if internal:
        group = internal[0]
        print(f"Internal testing group: {group['attributes']['name']} (already there)")
    else:
        group = call("POST", "/v1/betaGroups", {"data": {"type": "betaGroups", "attributes": {
            "name": "Tyler", "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]
        print("Internal testing group: made \"Tyler\" (every new build goes to it)")
    # add the Account Holder; internal testers have to be App Store Connect users
    try:
        users = call("GET", "/v1/users" + q({"filter[roles]": "ACCOUNT_HOLDER", "limit": 5}))["data"]
    except SystemExit:
        print("Couldn't list the team's users with this key; add yourself in TestFlight → Internal Testing")
        return
    have = call("GET", f"/v1/betaGroups/{group['id']}/betaTesters" + q({"limit": 50}))["data"]
    have_emails = {(t["attributes"].get("email") or "").lower() for t in have}
    for u in users:
        email = u["attributes"]["username"]
        print(f"::add-mask::{email}")
        if email.lower() in have_emails:
            print("The Account Holder is already an internal tester")
            continue
        try:
            call("POST", "/v1/betaTesters", {"data": {"type": "betaTesters", "attributes": {
                "email": email, "firstName": u["attributes"].get("firstName") or "Tyler",
                "lastName": u["attributes"].get("lastName") or "Locke"},
                "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group["id"]}]}}}})
            print("Added the Account Holder as an internal tester")
        except SystemExit:
            print("Couldn't add the Account Holder as a tester with this key; add yourself in TestFlight → Internal Testing")


def invite():
    """Send (or send again) the TestFlight invitation email to everyone in the internal group (Tyler, Nov 17)."""
    app = the_app()
    internal_testing(app["id"])
    groups = call("GET", "/v1/betaGroups" + q({"filter[app]": app["id"], "limit": 200}))["data"]
    sent = 0
    for g in [g for g in groups if g["attributes"].get("isInternalGroup")]:
        for t in call("GET", f"/v1/betaGroups/{g['id']}/betaTesters" + q({"limit": 50}))["data"]:
            email = t["attributes"].get("email") or ""
            if email:
                print(f"::add-mask::{email}")
            try:
                call("POST", "/v1/betaTesterInvitations", {"data": {"type": "betaTesterInvitations", "relationships": {
                    "app": {"data": {"type": "apps", "id": app["id"]}},
                    "betaTester": {"data": {"type": "betaTesters", "id": t["id"]}}}}})
                sent += 1
            except SystemExit:
                print("Apple didn't send this one (the message above says why)")
    print(f"Invitations sent: {sent}")
    if not sent:
        die("No invitation went out; add yourself in App Store Connect -> TestFlight -> Internal Testing")


def wait(number, minutes=40):
    app = the_app()
    end = time.time() + minutes * 60
    state = None
    while time.time() < end:
        found = builds(app["id"], number)
        if found:
            state = found[0]["attributes"]["processingState"]
            print(f"{time.strftime('%H:%M:%S')} build {number}: {state}")
            if state in ("VALID", "FAILED", "INVALID"):
                break
        else:
            print(f"{time.strftime('%H:%M:%S')} build {number}: not listed yet")
        time.sleep(60)
    with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a") as f:
        f.write(f"Build {number} on App Store Connect: {state or 'not listed yet'}\n")
    internal_testing(app["id"])
    if state in ("FAILED", "INVALID"):
        die(f"Apple marked build {number} {state}; App Store Connect emails the reason")
    if state != "VALID":
        print(f"Build {number} is still processing after {minutes} minutes; it shows in TestFlight when Apple finishes")


# ---------- the friends' external TestFlight (#581) ----------

FEEDBACK_EMAIL = "hello@tyleralocke.com"
PRIVACY_URL = "https://train.time2play.live/privacy"
BETA_DESCRIPTION = ("Virt is a workout tracker. Pick a starter plan or build your own, log your sets, and rest with a "
                    "timer that keeps going on the lock screen and in the Dynamic Island. Your workouts stay in your own "
                    "account. No AI, no ads, no analytics.")
WHAT_TO_TEST = ("Sign in with Apple, pick a plan, and run a workout: log sets, let a rest timer run with the phone "
                "locked, and try the Log set button on the lock screen. Tell us anything that feels off.")
REVIEW_NOTES = ("On the first screen choose \"Training for friends\" and sign in with Apple (any Apple ID works; no demo "
                "account needed). Then pick a starter plan and start today's workout. The other choice, \"Tyler's "
                "studio\", is the developer's own private sign-in and isn't meant for testers.")
GROUP = "Friends"


def one(path):
    r = call("GET", path, ok_missing=True)
    return (r or {}).get("data")


def external():
    app = the_app()
    aid = app["id"]

    # test information: what testers read in TestFlight, and where feedback goes
    locs = call("GET", f"/v1/apps/{aid}/betaAppLocalizations")["data"]
    attrs = {"description": BETA_DESCRIPTION, "feedbackEmail": FEEDBACK_EMAIL, "privacyPolicyUrl": PRIVACY_URL}
    loc = next((l for l in locs if l["attributes"]["locale"] == "en-US"), None)
    if loc:
        call("PATCH", f"/v1/betaAppLocalizations/{loc['id']}", {"data": {"type": "betaAppLocalizations", "id": loc["id"], "attributes": attrs}})
    else:
        call("POST", "/v1/betaAppLocalizations", {"data": {"type": "betaAppLocalizations", "attributes": dict(attrs, locale="en-US"),
            "relationships": {"app": {"data": {"type": "apps", "id": aid}}}}})
    print("Test information (description, feedback email, privacy link): set")

    # Beta App Review's contact and notes. The phone number is Tyler's to add in App Store Connect; never in the repo
    detail = one(f"/v1/apps/{aid}/betaAppReviewDetail")
    rattrs = {"contactFirstName": "Tyler", "contactLastName": "Locke", "contactEmail": FEEDBACK_EMAIL,
              "demoAccountRequired": False, "notes": REVIEW_NOTES}
    call("PATCH", f"/v1/betaAppReviewDetails/{detail['id']}", {"data": {"type": "betaAppReviewDetails", "id": detail["id"], "attributes": rattrs}})
    phone = detail["attributes"].get("contactPhone")
    print("Review contact and notes: set" + ("" if phone else " (no phone number yet: Tyler adds it in TestFlight -> Test Information)"))

    # the newest processed build
    valid = [b for b in builds(aid) if b["attributes"]["processingState"] == "VALID" and not b["attributes"].get("expired")]
    if not valid:
        die("No processed build to send")
    build = valid[0]
    num = build["attributes"]["version"]
    blocs = call("GET", f"/v1/builds/{build['id']}/betaBuildLocalizations")["data"]
    bloc = next((l for l in blocs if l["attributes"]["locale"] == "en-US"), None)
    if bloc:
        call("PATCH", f"/v1/betaBuildLocalizations/{bloc['id']}", {"data": {"type": "betaBuildLocalizations", "id": bloc["id"], "attributes": {"whatsNew": WHAT_TO_TEST}}})
    else:
        call("POST", "/v1/betaBuildLocalizations", {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": WHAT_TO_TEST},
            "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}})
    print(f"Build {num}: What to Test set")

    # the external group with a public link
    groups = call("GET", "/v1/betaGroups" + q({"filter[app]": aid, "limit": 200}))["data"]
    group = next((g for g in groups if g["attributes"]["name"] == GROUP and not g["attributes"].get("isInternalGroup")), None)
    gattrs = {"publicLinkEnabled": True, "feedbackEnabled": True}
    if group:
        group = call("PATCH", f"/v1/betaGroups/{group['id']}", {"data": {"type": "betaGroups", "id": group["id"], "attributes": gattrs}})["data"]
    else:
        group = call("POST", "/v1/betaGroups", {"data": {"type": "betaGroups", "attributes": dict(gattrs, name=GROUP),
            "relationships": {"app": {"data": {"type": "apps", "id": aid}}}}})["data"]
    call("POST", f"/v1/betaGroups/{group['id']}/relationships/builds", {"data": [{"type": "builds", "id": build["id"]}]})
    print(f"Group {GROUP!r}: public link on, build {num} in it")

    # Beta App Review
    state = (one(f"/v1/builds/{build['id']}/betaAppReviewSubmission") or {}).get("attributes", {}).get("betaReviewState")
    if state:
        print(f"Build {num} is already with Beta App Review: {state}")
    else:
        if not phone:
            die("Beta App Review needs a contact phone number. Add it in App Store Connect -> Virt -> TestFlight -> "
                "Test Information -> Beta App Review Information, then run this again")
        call("POST", "/v1/betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions",
            "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}})
        print(f"Build {num}: sent to Beta App Review")
    link = call("GET", f"/v1/betaGroups/{group['id']}")["data"]["attributes"].get("publicLink")
    msg = f"Friends' TestFlight link: {link or 'shows once Apple approves the build'}"
    print(msg)
    with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a") as f:
        f.write(msg + "\n")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "ready":
        ready()
    elif cmd == "probe":
        probe()
    elif cmd == "signin":
        sign_in_with_apple()
    elif cmd == "signing":
        signing(sys.argv[2])
    elif cmd == "wait":
        wait(sys.argv[2])
    elif cmd == "status":
        status()
    elif cmd == "invite":
        invite()
    elif cmd == "external":
        external()
    else:
        die(__doc__)
