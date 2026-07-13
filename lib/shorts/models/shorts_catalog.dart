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
}
