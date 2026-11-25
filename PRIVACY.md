# ContactMirror Privacy Policy

ContactMirror is an open-source macOS app that runs entirely on your own Mac.

- **No servers, no analytics.** ContactMirror has no backend. It never sends your data to the developer or any third party.
- **What it accesses:** your Google Contacts, Google Calendar and Google Tasks (through Google's APIs, with your permission), and the matching iCloud data on your Mac (Contacts, Calendar, Reminders, through macOS).
- **What it does with it:** it copies changes between your Google account and your iCloud data so they stay the same. Copies of your data exist only on your Mac (sync state and local backups in `~/Library/Application Support/ContactMirror/`) and in your own Google and iCloud accounts.
- **Credentials:** your Google sign-in token is stored on your Mac in a file only your user account can read (`~/Library/Application Support/ContactMirror/credentials.json`) and is used only to call Google's APIs on your behalf. You can revoke it at any time at https://myaccount.google.com/permissions or with *Sign Out* in the app.
- **Google API data:** ContactMirror's use of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.
- **Updates:** the app checks this GitHub repository's releases for new versions. GitHub receives a standard web request with no personal data.

Questions: open an issue at https://github.com/channelramble/ContactMirror/issues.
