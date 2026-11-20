import Foundation

/// Emoji codes: GitHub `:shortcodes:` (GitHub renders them) and classic text emoticons (`:)`,
/// `<3`, …) — found outside code, math and link addresses, for display and for Replace Emojis.
public enum EmojiCatalog {
    public struct Match: Equatable, Sendable {
        public var range: NSRange
        public var code: String
        public var emoji: String
        /// `:smile:`-style (GitHub shows these); false for text emoticons like `:)`.
        public var isShortcode: Bool
    }

    /// The most used GitHub shortcodes.
    public static let shortcodes: [String: String] = [
        "smile": "😄", "smiley": "😃", "grinning": "😀", "grin": "😁", "laughing": "😆", "satisfied": "😆",
        "joy": "😂", "rofl": "🤣", "sweat_smile": "😅", "blush": "😊", "innocent": "😇", "slightly_smiling_face": "🙂",
        "upside_down_face": "🙃", "wink": "😉", "relieved": "😌", "heart_eyes": "😍", "kissing_heart": "😘",
        "yum": "😋", "stuck_out_tongue": "😛", "stuck_out_tongue_winking_eye": "😜", "zany_face": "🤪",
        "sunglasses": "😎", "nerd_face": "🤓", "star_struck": "🤩", "partying_face": "🥳", "smirk": "😏",
        "unamused": "😒", "disappointed": "😞", "pensive": "😔", "worried": "😟", "confused": "😕",
        "slightly_frowning_face": "🙁", "frowning_face": "☹️", "persevere": "😣", "confounded": "😖",
        "tired_face": "😫", "weary": "😩", "pleading_face": "🥺", "cry": "😢", "sob": "😭", "triumph": "😤",
        "angry": "😠", "rage": "😡", "exploding_head": "🤯", "flushed": "😳", "scream": "😱", "fearful": "😨",
        "cold_sweat": "😰", "thinking": "🤔", "shushing_face": "🤫", "hand_over_mouth": "🤭", "neutral_face": "😐",
        "expressionless": "😑", "no_mouth": "😶", "roll_eyes": "🙄", "grimacing": "😬", "lying_face": "🤥",
        "sleeping": "😴", "sleepy": "😪", "dizzy_face": "😵", "mask": "😷", "nauseated_face": "🤢",
        "sneezing_face": "🤧", "hot_face": "🥵", "cold_face": "🥶", "cowboy_hat_face": "🤠", "clown_face": "🤡",
        "smiling_imp": "😈", "skull": "💀", "ghost": "👻", "alien": "👽", "robot": "🤖", "poop": "💩",
        "hankey": "💩", "see_no_evil": "🙈", "hear_no_evil": "🙉", "speak_no_evil": "🙊",
        "wave": "👋", "raised_hand": "✋", "ok_hand": "👌", "v": "✌️", "crossed_fingers": "🤞",
        "point_up": "☝️", "point_right": "👉", "point_left": "👈", "point_down": "👇", "+1": "👍",
        "thumbsup": "👍", "-1": "👎", "thumbsdown": "👎", "fist": "✊", "punch": "👊", "clap": "👏",
        "raised_hands": "🙌", "open_hands": "👐", "handshake": "🤝", "pray": "🙏", "muscle": "💪",
        "writing_hand": "✍️", "eyes": "👀", "brain": "🧠", "heart": "❤️", "orange_heart": "🧡",
        "yellow_heart": "💛", "green_heart": "💚", "blue_heart": "💙", "purple_heart": "💜", "black_heart": "🖤",
        "broken_heart": "💔", "sparkling_heart": "💖", "two_hearts": "💕", "100": "💯", "boom": "💥",
        "collision": "💥", "sparkles": "✨", "star": "⭐", "star2": "🌟", "dizzy": "💫", "fire": "🔥",
        "zap": "⚡", "snowflake": "❄️", "sunny": "☀️", "cloud": "☁️", "umbrella": "☔", "rainbow": "🌈",
        "ocean": "🌊", "earth_africa": "🌍", "earth_americas": "🌎", "globe_with_meridians": "🌐",
        "moon": "🌙", "tada": "🎉", "confetti_ball": "🎊", "balloon": "🎈", "gift": "🎁", "trophy": "🏆",
        "medal_sports": "🏅", "1st_place_medal": "🥇", "rocket": "🚀", "airplane": "✈️", "car": "🚗",
        "bike": "🚲", "ship": "🚢", "house": "🏠", "office": "🏢", "hourglass": "⌛", "watch": "⌚",
        "alarm_clock": "⏰", "calendar": "📆", "date": "📅", "memo": "📝", "pencil": "📝", "pencil2": "✏️",
        "book": "📖", "books": "📚", "notebook": "📓", "bookmark": "🔖", "page_facing_up": "📄",
        "clipboard": "📋", "pushpin": "📌", "paperclip": "📎", "scissors": "✂️", "file_folder": "📁",
        "open_file_folder": "📂", "chart_with_upwards_trend": "📈", "chart_with_downwards_trend": "📉",
        "bar_chart": "📊", "email": "📧", "envelope": "✉️", "inbox_tray": "📥", "outbox_tray": "📤",
        "package": "📦", "phone": "☎️", "iphone": "📱", "computer": "💻", "desktop_computer": "🖥️",
        "keyboard": "⌨️", "printer": "🖨️", "camera": "📷", "movie_camera": "🎥", "tv": "📺",
        "bulb": "💡", "flashlight": "🔦", "battery": "🔋", "electric_plug": "🔌", "mag": "🔍",
        "mag_right": "🔎", "lock": "🔒", "unlock": "🔓", "key": "🔑", "hammer": "🔨", "wrench": "🔧",
        "gear": "⚙️", "link": "🔗", "chains": "⛓️", "toolbox": "🧰", "test_tube": "🧪", "microscope": "🔬",
        "bell": "🔔", "no_bell": "🔕", "loudspeaker": "📢", "mega": "📣", "speech_balloon": "💬",
        "thought_balloon": "💭", "moneybag": "💰", "dollar": "💵", "euro": "💶", "credit_card": "💳",
        "coffee": "☕", "tea": "🍵", "beer": "🍺", "beers": "🍻", "wine_glass": "🍷", "pizza": "🍕",
        "hamburger": "🍔", "cake": "🍰", "birthday": "🎂", "apple": "🍎", "lemon": "🍋", "cookie": "🍪",
        "dog": "🐶", "cat": "🐱", "mouse": "🐭", "rabbit": "🐰", "fox_face": "🦊", "bear": "🐻",
        "panda_face": "🐼", "koala": "🐨", "tiger": "🐯", "lion": "🦁", "cow": "🐮", "pig": "🐷",
        "frog": "🐸", "monkey": "🐒", "chicken": "🐔", "penguin": "🐧", "bird": "🐦", "owl": "🦉",
        "unicorn": "🦄", "bee": "🐝", "bug": "🐛", "butterfly": "🦋", "snail": "🐌", "turtle": "🐢",
        "snake": "🐍", "octopus": "🐙", "fish": "🐟", "whale": "🐳", "dolphin": "🐬", "seedling": "🌱",
        "herb": "🌿", "four_leaf_clover": "🍀", "deciduous_tree": "🌳", "evergreen_tree": "🌲",
        "cactus": "🌵", "tulip": "🌷", "rose": "🌹", "sunflower": "🌻", "cherry_blossom": "🌸",
        "white_check_mark": "✅", "heavy_check_mark": "✔️", "ballot_box_with_check": "☑️", "x": "❌",
        "negative_squared_cross_mark": "❎", "heavy_plus_sign": "➕", "heavy_minus_sign": "➖",
        "warning": "⚠️", "no_entry": "⛔", "no_entry_sign": "🚫", "stop_sign": "🛑", "construction": "🚧",
        "rotating_light": "🚨", "information_source": "ℹ️", "question": "❓", "grey_question": "❔",
        "exclamation": "❗", "heavy_exclamation_mark": "❗", "bangbang": "‼️", "interrobang": "⁉️",
        "arrow_right": "➡️", "arrow_left": "⬅️", "arrow_up": "⬆️", "arrow_down": "⬇️",
        "arrows_counterclockwise": "🔄", "repeat": "🔁", "new": "🆕", "free": "🆓", "up": "🆙",
        "cool": "🆒", "ok": "🆗", "sos": "🆘", "top": "🔝", "soon": "🔜", "copyright": "©️",
        "registered": "®️", "tm": "™️", "red_circle": "🔴", "large_blue_circle": "🔵", "green_circle": "🟢",
        "yellow_circle": "🟡", "white_circle": "⚪", "black_circle": "⚫", "small_red_triangle": "🔺",
        "pin": "📍", "round_pushpin": "📍", "triangular_flag_on_post": "🚩", "checkered_flag": "🏁",
        "flag_white": "🏳️", "rainbow_flag": "🏳️‍🌈", "slovakia": "🇸🇰", "czech_republic": "🇨🇿", "eu": "🇪🇺",
        "us": "🇺🇸", "uk": "🇬🇧", "gb": "🇬🇧", "de": "🇩🇪", "fr": "🇫🇷", "it": "🇮🇹", "es": "🇪🇸", "jp": "🇯🇵",
        "octocat": "🐙", "shipit": "🐿️", "sparkle": "❇️", "zzz": "💤", "dash": "💨", "sweat_drops": "💦",
        "musical_note": "🎵", "notes": "🎶", "art": "🎨", "game_die": "🎲", "dart": "🎯", "soccer": "⚽",
        "basketball": "🏀", "tennis": "🎾", "running": "🏃", "walking": "🚶", "man_technologist": "👨‍💻",
        "woman_technologist": "👩‍💻", "technologist": "🧑‍💻", "construction_worker": "👷", "detective": "🕵️",
        "ninja": "🥷", "baby": "👶", "boy": "👦", "girl": "👧", "man": "👨", "woman": "👩", "family": "👪",
        "busts_in_silhouette": "👥", "bust_in_silhouette": "👤", "crown": "👑", "gem": "💎", "ring": "💍",
        "lipstick": "💄", "eyeglasses": "👓", "tshirt": "👕", "jeans": "👖", "shoe": "👞", "tophat": "🎩",
        "mortar_board": "🎓", "school_satchel": "🎒", "bookmark_tabs": "📑", "label": "🏷️", "lock_with_ink_pen": "🔏",
        "recycle": "♻️", "infinity": "♾️", "heavy_dollar_sign": "💲", "hourglass_flowing_sand": "⏳",
        "stopwatch": "⏱️", "timer_clock": "⏲️", "thermometer": "🌡️", "pill": "💊", "syringe": "💉",
        "dna": "🧬", "atom_symbol": "⚛️", "milky_way": "🌌", "volcano": "🌋", "mountain": "⛰️",
        "camping": "🏕️", "beach_umbrella": "🏖️", "desert_island": "🏝️", "national_park": "🏞️",
        "stadium": "🏟️", "classical_building": "🏛️", "building_construction": "🏗️", "hospital": "🏥",
        "bank": "🏦", "hotel": "🏨", "school": "🏫", "church": "⛪", "tent": "⛺", "fountain": "⛲",
        "bridge_at_night": "🌉", "city_sunset": "🌆", "sunrise": "🌅", "stars": "🌠", "fireworks": "🎆",
        "sparkler": "🎇", "christmas_tree": "🎄", "jack_o_lantern": "🎃", "santa": "🎅", "snowman": "⛄"
    ]

    /// Text emoticons Replace Emojis turns into emoji (GitHub leaves these as text). Longest first.
    public static let emoticons: [(String, String)] = [
        (":-)", "🙂"), (":)", "🙂"), (":-(", "🙁"), (":(", "🙁"), (";-)", "😉"), (";)", "😉"),
        (":-D", "😃"), (":D", "😃"), (":-P", "😛"), (":P", "😛"), (":-p", "😛"), (":p", "😛"),
        (":-O", "😮"), (":O", "😮"), (":-o", "😮"), (":'(", "😢"), (":-|", "😐"), (":|", "😐"),
        (":-/", "😕"), ("</3", "💔"), ("<3", "❤️"), ("8-)", "😎"), (":-*", "😘"), (":*", "😘")
    ]

    /// Codes in `source`, outside code blocks, inline code, math, link / image addresses and HTML.
    public static func matches(in source: String, includeEmoticons: Bool = true) -> [Match] {
        let ns = source as NSString
        guard ns.length > 0 else { return [] }
        var blocked = [Bool](repeating: false, count: ns.length)
        func block(_ range: NSRange) {
            for i in range.location..<min(ns.length, NSMaxRange(range)) { blocked[i] = true }
        }
        for span in MarkdownSyntax.spans(in: source) {
            switch span.kind {
            case .codeBlock, .inlineCode, .inlineMath: block(span.group)
            case .link, .image: if span.role == .marker { block(span.range) }
            default: break
            }
        }
        var found: [Match] = []
        var i = 0
        let chars = Array(source.utf16)
        func isWordChar(_ c: unichar) -> Bool {
            (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 95
        }
        while i < chars.count {
            if blocked[i] { i += 1; continue }
            // :shortcode:
            if chars[i] == 58, i + 2 < chars.count {
                var j = i + 1
                while j < chars.count, j - i <= 40, isWordChar(chars[j]) || chars[j] == 43 || chars[j] == 45 { j += 1 }
                if j < chars.count, chars[j] == 58, j > i + 1, !blocked[j] {
                    let name = ns.substring(with: NSRange(location: i + 1, length: j - i - 1))
                    if let emoji = shortcodes[name] {
                        found.append(Match(range: NSRange(location: i, length: j - i + 1), code: ":\(name):", emoji: emoji, isShortcode: true))
                        i = j + 1
                        continue
                    }
                }
            }
            // Emoticons: standalone (start / whitespace before, end / whitespace / punctuation after).
            if includeEmoticons, i == 0 || [32, 9, 10, 40].contains(chars[i - 1]) {
                var matched = false
                for (code, emoji) in emoticons {
                    let length = (code as NSString).length
                    guard i + length <= chars.count, ns.substring(with: NSRange(location: i, length: length)) == code else { continue }
                    let end = i + length
                    if end < chars.count, !(Set<unichar>([32, 9, 10, 46, 44, 33, 63, 41]).contains(chars[end])) { continue }
                    if (i..<end).contains(where: { blocked[$0] }) { continue }
                    found.append(Match(range: NSRange(location: i, length: length), code: code, emoji: emoji, isShortcode: false))
                    i = end
                    matched = true
                    break
                }
                if matched { continue }
            }
            i += 1
        }
        return found
    }

    /// Replaces every match with its emoji (back to front, so ranges stay valid).
    public static func replaceAll(in source: String) -> (text: String, count: Int) {
        let found = matches(in: source)
        let text = NSMutableString(string: source)
        for match in found.reversed() { text.replaceCharacters(in: match.range, with: match.emoji) }
        return (text as String, found.count)
    }
}
