import 'dart:convert';

/// Pure helpers for keeping a JanitorAI account session alive across app
/// launches and Cloudflare challenges. Kept out of the WebView proxy so both
/// rules — what makes a stored session cookie survive, and when the access
/// token it carries has to be refreshed — are testable without a WebView.

/// Whether [name] is one of the Supabase session cookies JanitorAI signs in
/// with (`sb-<ref>-auth-token`, plus its `.0`, `.1`, … chunks).
///
/// These are the only cookies that must survive a Cloudflare cookie wipe: lose
/// one chunk and the session is gone, which is what "logged out again" looks
/// like to the user.
bool isJanitorAuthCookie(String name) =>
    name.startsWith('sb-') && name.contains('-auth-token');

/// How long a restored auth cookie should live, in milliseconds since epoch.
///
/// The expiry read back from the platform cannot be trusted. Android's WebView
/// returns no attributes at all unless `GET_COOKIE_INFO` is supported, and when
/// it is, a `Max-Age` is converted as `now + maxAge` **milliseconds** instead of
/// seconds — so a 400-day cookie reads back as roughly nine hours. Re-setting
/// either value downgrades a persistent login to something that dies with the
/// process (a null expiry makes it session-only), which is exactly the "have to
/// log in again after every launch" report.
///
/// So an expiry is only kept when it is plausibly a real one; anything missing
/// or suspiciously near is replaced with Supabase's own horizon.
int janitorAuthCookieExpiry(int? readBackMs, {required int nowMs}) {
  const minimumPlausible = Duration(days: 2);
  const supabaseDefault = Duration(days: 400);
  if (readBackMs != null &&
      readBackMs - nowMs >= minimumPlausible.inMilliseconds) {
    return readBackMs;
  }
  return nowMs + supabaseDefault.inMilliseconds;
}

/// The expiry stamped in a JWT's `exp` claim, or null when [jwt] carries none
/// that can be read.
DateTime? janitorTokenExpiry(String jwt) {
  final parts = jwt.split('.');
  if (parts.length != 3) return null;
  final Map<String, dynamic> payload;
  try {
    final decoded = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final parsed = jsonDecode(decoded);
    if (parsed is! Map) return null;
    payload = Map<String, dynamic>.from(parsed);
  } on Object {
    return null;
  }
  final exp = payload['exp'];
  if (exp is! num) return null;
  return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true);
}

/// Whether the access token [jwt] is spent — expired, or close enough that a
/// request made with it would arrive after it lapsed.
///
/// JanitorAI's Supabase access token lives about an hour, while the refresh
/// token stored beside it in the same cookie lives for weeks. Glaze never
/// refreshes the pair itself — the page's own Supabase client does, on load —
/// so a session that is perfectly valid still hands out a stale JWT the first
/// time the app is opened the next day. Every authenticated call then answers
/// 401 and reads as "session expired, log in again" when nothing of the sort
/// happened: the page just has to reload first.
///
/// A token with no readable `exp` is treated as usable — a request that fails
/// says more than a guess here.
bool isJanitorTokenExpired(
  String jwt, {
  Duration skew = const Duration(seconds: 60),
  DateTime? now,
}) {
  final expiry = janitorTokenExpiry(jwt);
  if (expiry == null) return false;
  final at = (now ?? DateTime.now().toUtc()).add(skew);
  return !expiry.isAfter(at);
}
