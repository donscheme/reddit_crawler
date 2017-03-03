
/// Converts the result JSON from the Reddit `/search?q=...` API to
/// a TSV.
Iterable<String> redditJson2tsv(List<Map<String, Object>> json) sync* {
  for (var record in json) {
    final String kind = record['kind'];
    final Map<String, Object> data = record['data'] as Map<String, Object>;
    final String subreddit = data['subreddit'];
    final int score = data['score'];
    final int ups = data['ups'];
    final int downs = data['downs'];
    final String domain = data['domain'];
    final String permalink = data['permalink'];
    final DateTime created = new DateTime.fromMillisecondsSinceEpoch(
        ((data['created_utc'] as num) * 1000).round(),
        isUtc: true);
    final String dayCreated = "${created.year}-${created.month}-${created.day}";
    final String monthCreated = "${created.year}-${created.month}-1";
    final String quarterCreated = "${created.year}-"
        "${_monthToFirstMonthInQuarter(created.month)}-1";
    final int numComments = data['num_comments'];
    yield "$kind\t$subreddit\t$score\t$ups\t$downs\t$numComments\t"
        "$domain\t"
        "${created.millisecondsSinceEpoch}\t"
        "$dayCreated\t$monthCreated\t$quarterCreated\t"
        "$permalink";
  }
}

int _monthToQuarter(int month) => (month - 1) ~/ 3 + 1;

int _monthToFirstMonthInQuarter(int month) =>
    1 + (_monthToQuarter(month) - 1) * 3;
