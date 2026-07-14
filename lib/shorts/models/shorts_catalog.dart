/// Static catalog of selectable languages and categories.
/// Kept separate from remote data — these drive the onboarding
/// screens and map to iTunes search terms/genre filters.
class ShortsCatalog {
  ShortsCatalog._();

  static const List<String> languages = [
    'Hindi',
    'English',
    'Punjabi',
    'Bhojpuri',
    'Tamil',
    'Telugu',
    'Malayalam',
    'Kannada',
    'Marathi',
    'Gujarati',
    'Bengali',
    'Japanese',
    'Korean',
    'French',
    'Russian',
  ];

  static const int maxLanguageSelection = 3;

  /// category label -> search query hint appended to iTunes search term
  static const Map<String, String> categories = {
    'Trending': 'top hits',
    'New Releases': 'new',
    'Viral': 'viral',
    'Love': 'love songs',
    'Romantic': 'romantic',
    'Sad': 'sad songs',
    'Party': 'party',
    'Workout': 'workout',
    'Chill': 'chill',
    'LoFi': 'lofi',
    'Focus': 'focus',
    'Sleep': 'sleep',
    'Road Trip': 'road trip',
    'Hip Hop': 'hip hop',
    'Rap': 'rap',
    'Rock': 'rock',
    'Pop': 'pop',
    'EDM': 'edm',
    'Instrumental': 'instrumental',
    'Classical': 'classical',
    '90s': '90s hits',
    'Retro': 'retro',
    'Anime': 'anime',
    'K-Pop': 'kpop',
    'J-Pop': 'jpop',
    'Punjabi Hits': 'punjabi hits',
    'Bhojpuri Hits': 'bhojpuri hits',
    'English Top Songs': 'english top songs',
  };

  /// iTunes storefront country code per language — improves relevance
  /// since iTunes search is heavily storefront-biased.
  static const Map<String, String> languageToCountry = {
    'Hindi': 'IN',
    'Punjabi': 'IN',
    'Bhojpuri': 'IN',
    'Tamil': 'IN',
    'Telugu': 'IN',
    'Malayalam': 'IN',
    'Kannada': 'IN',
    'Marathi': 'IN',
    'Gujarati': 'IN',
    'Bengali': 'IN',
    'English': 'US',
    'Japanese': 'JP',
    'Korean': 'KR',
    'French': 'FR',
    'Russian': 'RU',
  };

  /// Well-known artists per language, used as extra search seed terms.
  /// iTunes' plain-text relevance ranking under the IN storefront
  /// skews heavily toward Hindi/mainstream Bollywood regardless of
  /// what language word you put in the query — "bhojpuri party" can
  /// still surface Hindi results if iTunes' catalog coverage for that
  /// exact phrase is thin. Anchoring searches to real artist names
  /// known for that language is a much stronger relevance signal and
  /// reliably pulls in genuinely-that-language content.
  static const Map<String, List<String>> languageSeedArtists = {
    'Bhojpuri': [
      'Khesari Lal Yadav',
      'Pawan Singh',
      'Kalpana',
      'Ritesh Pandey',
      'Neelkamal Singh',
    ],
    'Punjabi': [
      'Diljit Dosanjh',
      'Sidhu Moose Wala',
      'AP Dhillon',
      'Karan Aujla',
      'Guru Randhawa',
    ],
    'Tamil': ['Anirudh Ravichander', 'A.R. Rahman', 'Sid Sriram'],
    'Telugu': ['Devi Sri Prasad', 'S. Thaman'],
    'Malayalam': ['M. Jayachandran', 'Sushin Shyam'],
    'Kannada': ['Arjun Janya', 'V. Harikrishna'],
    'Marathi': ['Ajay-Atul'],
    'Gujarati': ['Kinjal Dave', 'Geeta Rabari'],
    'Bengali': ['Arijit Singh Bengali', 'Anupam Roy'],
    'Hindi': ['Arijit Singh', 'Neha Kakkar', 'Jubin Nautiyal'],
  };

  /// Coarse keyword signals used to sanity-check a result actually
  /// belongs to the claimed language, catching cases where iTunes
  /// returned a mismatched (usually Hindi) result despite a
  /// language-scoped query. Not exhaustive — a heuristic safety net,
  /// not a hard language classifier.
  static const Map<String, List<String>> languageTitleHints = {
    'Bhojpuri': ['bhojpuri', 'bhojpuriya'],
    'Punjabi': ['punjabi', 'panjabi'],
  };
}
