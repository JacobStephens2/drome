# My sister's Problem and the Description of How she does Hard 75

My sister is going through 75 Hard right now, and she wants a way to track her progress. She's doing it with friends of hers, though she looks at the current app, and she doesn't want to pay $40 for an app that looks to her to pretty much just be a checklist.

Part of what motivates her is the satisfaction of checking all the boxes - of completing the entire list. She also wants to improve her habits, so she resonates with the idea that sometimes 14 or 21 days actually isn't quite enough to get a new habit going.

## Work arounds

She is recording her progress on iOS Google Sheets on her phone, which represents some of the information my sister has been tracking - though the specific oz of water quantity she captures in a different app.

She's tracking her workouts with Apple Fitness / her Apple Watch, which she may continue to do in order to share with others in the Apple Health / Activity sharing area - a sharing separate from her Hard 75 discipline.

My sister is using two apps to track her completion - a separate app to track her water drinking. A downside with that app though is that she can only enter water in 16 ounce increments which is a bit annoying to her. That other app fills up a llama with water, which is fun - until the llama looks like it is drowning. 

She's also using a separate app to share progress. She has a group chat with some friends who are doing it where they take screenshots of their workouts and share them to track their progress.

## Rules she and her friends loosen

My sister and her friends who are doing this with her are not holding to the if you fail one day you need to restart until you get to 75 days consecutive.

My sister is counting a day as her waking hours - the time from when she wakes up to when she goes to sleep, which sometimes rolls into the next calendar day. The flexibility of a Google Sheet makes it easy for her to know that last night she read 10 pages even if she didn't check it off last night, but then today she can check that off.

## Additions

She also added a once-a-week extra column of her own to the spreadsheet.

My sister also keeps a Diet Parameters tab, a second tab in her sheet, where she notes her YES FOODS and her NO FOODS, as well as some recipes / meals that work well for what nutrition/diet and no junk.

## Feel

There's an intensity to the feel of this program. My sister takes a very devoted approach to it. She referenced Andy Frisella's saying if you drank 167 ounces, you're not done yet, drink that final ounce.

# Solution for my sister and her friends

An app which is free and easier to navigate than Google Sheets, and a more impactful hit of completion when a day is fully checked - some kind of hit of yeah, I did something hard, but also a touch of silly with filling up a llama or camel or something with water.

The one app could do both allowing tracking completion of the tasks each day and the water usage.

The app should by default not enforce the places that my sister and her group loosen on the rules, such as restarting if if you don't complete a day, but there should be an optional purist mode which does enforce these rules as originally written by Andy.

I can imagine my sister being able to enter things on her watchOS watch being useful, though iOS would be sufficient. She thinks all of her friends are also using iOS, though I imagine there are also people on Android / Wear OS who would be interested in this. I can imagine it being useful as well for people to access their account / information on desktop as well via the web.

Thinking about her weekly add-on and some rule loosenings, the app should either offer the user the way to add custom extra bits, or just initially offer one weekly add-on. I imagine this is more specific to her than her friends, so I would want this as an opt-in feature rather than an on-by-default feature.

I want the animal to be filled up with water to be a camel.

## App name brainstorm

ChangeIt: An App for 75 Hard, NotSoft, Grazz, Mrack, Kark - some coined name may be easier to monetize / get a good domain name for / have legal legroom for.

## Tech Stack

The initial MVP I think somewhere from just iOS local to iOS + watchOS + server (which can be hosted on my stephens.page server, which can be accessed from Jacob's macbook as jacob@stephens.page). Then other platforms such as web and Android and Wear OS could be added in another phase.

It would be good to have a shared logic core to ensure the rules hold the same across platforms. This could be a shared Rust core - maybe TypeScript? I prefer the Rust though. I've also considered full-stack Rust via Rust + Axum on server, maybe Dioxus for different platforms, or Leptos for web, or there could be wasm-bindgen to connect to TypeScript/JavaScript, though that can feel a bit awkward, but is manageable, but the TypeScript frontend opens a larger ecosystem than a more purely WebAssembly frontend web. 

For the mobile apps though, maybe native Swift and Kotlin would be best though for more health feature integrations as compared to Dioxus or a Capacitor wrapped web app. Though if we go with Capacitor for velocity, then the watchOS app could separately sync with the server. 

## Deployment

I have an Apple Developer ID (LHY8W725A8) and can distribute by TestFlight. 

## Monetization

I also want to add a payment system and have a freemium model, where the user can use the app locally for free, but to have the server side features they need to pay a monthly fee. I have a single-member LLC, Stephens Page LLC (https://stephens.page, https://github.com/JacobStephens2/stephens-page-llc/blob/main/business-identity.md), and I have a Mercury account and Stripe account already connected to it. I'm open to using Revenue Cat or anything else that would be a good fit for this setup.

## Design

The camel can be the icon for the app, and generally serve as some inspiration for the appearance of the app, as well as the general intense discipline and hi-performance self improvement vibe.