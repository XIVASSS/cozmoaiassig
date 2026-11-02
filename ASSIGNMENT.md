# Sweep assignment

This file is the source of truth for the app. The product brief is the [Library Contents Claim Agent](https://docs.google.com/document/d/1U-Q1EBCZl9hDmOzVfPOmk453Qe5UAM_AZKcmISPbcec/edit). If this file and a later idea disagree, this file wins.

Sweep is a native iPhone app for one contents claim. A person walks one enclosed room once. The phone measures, reads, and prices. The voice only says what the phone has already decided.

## Locked choices

- Device: iPhone without LiDAR. The review build runs on the phone alone.
- Scale: a bank card, ISO ID-1, 85.60 mm by 53.98 mm. ARKit motion tracking carries that scale. Books use the card. The room uses the card’s correction of the tracking. If they disagree past the threshold, both numbers stay visible and they are not averaged.
- Eyes stay on the device: Vision text, rectangle detection, image classification, blur and glare.
- Mouth: the state machine chooses the sentence. Gemini Live may speak that sentence when a key is present. If it is not connected, the phone speaks the same sentence. The model is never asked for a title, a price, or a total.
- Ear: on-device speech. Unclear phrases can be classified by Gemini into a fixed list of intents. The list is confirm, first edition, skip shelf, print, original, United States dollars, or none.
- Claim locale: United States, dollars, confirmed out loud or with the chip. It is not assumed in silence.
- Second market: Germany, euros, for the same ten identified books. Empty if AbeBooks returns nothing.
- A weak read is a hunch. It is spoken as a hunch, stored in `candidate_title`, status `unidentified`, and kept out of the identified count and the money until the person confirms it.
- Appraisal, not a price: first edition, signed, antiquarian (first published before 1850), art that is not confirmed as a print, and any sourced price at or above the threshold (default 75 USD).
- Graded capture: a small library study room with a door, about 60 to 120 books, two shelves, at least eight things that are not books. Permission, no people in frame. Ground truth is collected on a prep visit, before the demo take.

## What the person hears

Opening, verbatim:

> We are going to walk this room once. First, country and currency. Then the card on the shelf, flat, for two seconds.

A bad frame is a physical instruction:

- Soft, blurred, or glaring: “Stop. Step closer to the left of that shelf and hold still.”
- Moving too fast: “Back half a step. Hold the card flat on that shelf again.”
- A shelf left behind: “You passed a shelf. Pan back to it and hold.”

“Yes, that one” promotes the latest hunch. “That is a first edition” sends it to appraisal and clears any price. “Skip that shelf” or “those are not mine” drops that shelf from the totals and leaves the lines in the file. “It is a print” is the only way a framed picture leaves appraisal, and it still has no price until a listing exists.

## What may be filed

- A title, only when on-device text and a catalogue record agree, or when the person confirms a hunch.
- A price, only with a source name, a URL, and the retrieval time. Replacement comes from an AbeBooks new listing or a Google Books list price in the claim currency. Used value comes from an AbeBooks used listing. Another currency is converted with a Frankfurter rate, `converted: true`, and both URLs. No listing means a null amount.
- Centimetres, only from the card and the current distance. No card means null dimensions.
- Room area, only from planes seen on this walk, multiplied by the card correction. `scale_method` names that method.
- Totals, only by summing the lines in code.

An empty field is correct when the system does not know. A non-book with no brand and no listing stays unpriced. Ranges are not invented.

## What this app does not do

No login, no policy admin, no carrier connectors, no barcode or ISBN entry, no request to pull books down or photograph them one by one, no model-written price, no hardcoded shelf or room, no auto-priced art, and no launch into the camera. Uploading a video does not create a claim. A practice replay runs the same rules on scripted observations and is labeled practice.

Floor-plan drawing, condition grades, and multi-room merge are out until one room’s packet is honest.

## Packet

Each finished walk writes `claim_packet.json` and `report.html`. Later confirmations write the next version. `frame_ref` is a path under that session’s `frames` folder. The review queue is derived from the lines.

## Pass bars

These are measured against ground truth collected by hand, on the whole room.

- Book count within 5 percent.
- At least 70 percent of human-legible spines correct, and no more than 3 percent confidently wrong.
- Spine size within 15 percent on 20 hand-measured spines.
- Book prices within 25 percent of 15 hand-checked prices of the same source type.
- At least 80 percent of non-book items, right category.
- Floor area within 10 percent. Wall area within 15 percent.
- Packet within 5 minutes of the end of the walk.
