# Privacy policy

Lumen Voice is a free app for iPhone and Apple Watch. This page says what the app does with your words, your key, and your chat.

## What you say

The microphone is used only when you hold the button, tap Talk, or turn on listening for the word "Lumen" while the app is open on screen.

On the iPhone, speech is turned into text on the device. The recording is not kept. The text of your question, and the recent chat needed to answer it, is sent to the service you chose:

- An API key you paste (Grok, Claude, Gemini, Groq, or OpenRouter). The request goes to that provider.
- Your own server. The request goes to the address you entered.
- A cloud or custom address you entered. The request goes to that address.

The developer of this app does not receive those requests and does not run the AI service.

On the Apple Watch, a question is recorded on the watch. If the iPhone is nearby, the recording is sent to the Lumen app on that iPhone, turned into text there, and then handled like a question you asked on the phone. The recording is deleted. If the iPhone is not nearby, the watch tries to turn the recording into text on the watch. If it cannot, it can send the recording to the server you already set up, ask that server to turn it into text, and then delete the recording.

## What is stored on your devices

- The API key and the token for your own server are stored in the iPhone Keychain. They stay on that iPhone. They are not copied to iCloud Keychain.
- The cloud address and its key can be copied to the paired Apple Watch so the watch can answer when the iPhone is away. The key is stored in the watch Keychain.
- Chat on the iPhone is saved in the app's private storage on that iPhone. You can clear it in Settings.
- Chat on the Apple Watch is saved on that watch.
- Settings such as the server address, voice, and connection mode are saved on the device.

Demo Mode uses sample replies and does not send your words anywhere.

## Before a question is sent

The iPhone shows a screen before it sends the text of what you say or type. That text goes to Grok, Claude, Gemini, Groq, OpenRouter, a cloud address you enter, or your own server, so you can get answers.

The Apple Watch shows a matching screen. The watch can send your speech, or the text of what you say, to your own server or a cloud address from the iPhone when the iPhone has not agreed. The iPhone may then send that text to Grok, Claude, Gemini, Groq, or OpenRouter.

The buttons are Agree and Not now. Agree allows those sends. Not now means nothing is sent. The choice is stored on that device. Settings on each device can change it. The screen links to this page.

## What this app does not do

- No ads.
- No sale of your data.
- No tracking, and no tracking across other companies' apps or websites.
- No account with the developer.
- No purchase inside the app.

## Contact

Questions about this policy go to the issues list on GitHub: https://github.com/ouijabored66/lumen-voice/issues
