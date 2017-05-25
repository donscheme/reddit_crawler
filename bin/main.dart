// Copyright (c) 2017, Filip Hracek. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:reddit_crawl/config.dart' show clientId, appSecret;
import 'package:reddit_crawl/json2csv.dart';

final Logger log = new Logger("main");

Future<Null> main(List<String> arguments) async {
  final parser = new ArgParser(allowTrailingOptions: true);

  parser..addFlag('verbose', abbr: 'v', help: "Verbose mode.");

  final options = parser.parse(arguments);

  final bool verbose = options['verbose'];

  Logger.root.onRecord.listen((ev) {
    if (ev.level >= Level.SEVERE) {
      stderr.writeln("[${ev.level}] -- ${ev.loggerName} -- ${ev.message}");
    } else if (verbose) {
      stdout.writeln("[${ev.level}] -- ${ev.loggerName} -- ${ev.message}");
    }
  });

  if (options.rest.length != 1) {
    print("Exactly one argument is requred: a name of a technology.");
    print("\nAdditional options:");
    print(parser.usage);
    exitCode = 2;
    return;
  }

  final language = options.rest.single.trim();

  final client = new http.Client();

  while (!await _auth(client)) {
    log.warning("Couldn't authenticate. Retrying in <10 seconds.");
    await new Future.delayed(new Duration(seconds: _random.nextInt(10)));
  }

  //  final subreddits = await findSubreddits("programming", client);
  //  print(JSON.encode(subreddits));
  //  client.close();
  //  return;

  final now = new DateTime.now();
  const int monthCount = 6;

  final List<Map<String, Object>> entities = [];

  for (int i = 0; i < monthCount; i++) {
    final to = new DateTime(now.year, now.month + 1 - i);
    final from = new DateTime(to.year, to.month - 1);

    log.info("Getting for ${from.year}-${from.month}.");
    await getFullListing(language, from, to, client, entities);
  }

  client.close();

  log.info("\nFound ${entities.length} articles.");

  final output = jsonEncoder.convert(entities);

  final file = new File(
      "output-$language-${now.toIso8601String().substring(0, 10)}.json");
  await file.writeAsString(output);
  log.info("Output written to $file");

  final tsvFile = new File(path.withoutExtension(file.path) + ".tsv");
  final tsvOutput = submissionsJson2tsv(entities);

  await tsvFile.writeAsString(tsvOutput.join('\n'));
  log.info("TSV written to $tsvFile");

  print("\nOutput written to files:\n\t- $file\n\t- $tsvFile");
}

/// List of top programming and SW development subreddits that are generic
/// or didactic in nature.
///
/// Together, these 12 subreddits have 1M+ subscribers (cumulative).
const List<String> subreddits = const [
  // Generic
  "programming",
  "WatchPeopleCode",
  "AskProgramming",
  "programmingtools",
  "programmerchat",
  // Didactic
  "learnprogramming",
  "dailyprogrammer",
  "tinycode",
  "programmingchallenges",
  "code",
  "ProgrammingBuddies",
  "programming_tutorials"
];

var accessToken;

final jsonEncoder = new JsonEncoder.withIndent('  ');

/// The url part that creates a 'temporary multireddit' (like `pics+aww` in
/// http://www.reddit.com/r/pics+aww).
final String subredditsInUrl = subreddits.join('+');

final userAgent = "Dart watcher tool (github.com/filiph)";

final _random = new Random();

String encodeAuth(String username, String password) {
  final both = "$username:$password";
  final bytes = UTF8.encode(both);
  final base64 = BASE64.encode(bytes);
  return base64;
}

/// Gets the listing even if it's multi-page.
///
/// https://www.reddit.com/dev/api/#GET_subreddits_search
Future<List<Map<String, Object>>> findSubreddits(
    String query, http.Client client) async {
  final queryParameters = {
    'q': query,
  };

  final List<Map<String, Object>> entities = [];

  String afterToken;

  // ignore: literal_only_boolean_expressions
  while (true) {
    await new Future.delayed(new Duration(seconds: _random.nextInt(10)));
    if (afterToken != null) {
      queryParameters['after'] = afterToken;
    }
    final uri = Uri
        .parse("https://oauth.reddit.com/subreddits/search")
        .replace(queryParameters: queryParameters);
    final Map<String, dynamic> jsonObject = await getListingJson(client, uri);
    if (jsonObject == null || jsonObject['data'] == null) {
      log.warning(
          "getListingJson returned null or a JSON that doesn't contain data");
      log.info(jsonEncoder.convert(jsonObject));
      await new Future.delayed(new Duration(seconds: _random.nextInt(30)));
      log.info("re-authenticating");
      if (!await _auth(client)) {
        log.warning("ERROR: couldn't re-authenticate");
      }
      await new Future.delayed(new Duration(seconds: _random.nextInt(30)));
      continue;
    }
    entities.addAll(jsonObject['data']['children']);
    stdout.write(".");
    afterToken = jsonObject['data']['after'];
    if (afterToken == null) break;
  }

  return entities;
}

/// Returns the decoded listing object returned by the Reddit API, or `null`
/// if there was a problem (wrong response from the API or closed socket).
///
/// The returned object is documented here:
/// https://www.reddit.com/dev/api/#listings
Future<Map<String, dynamic>> getListingJson(http.Client client, Uri uri) async {
  Map<String, dynamic> jsonObject;
  try {
    final nextJson = await _getListing(client, uri);
    jsonObject = JSON.decode(nextJson);
  } on FormatException {
    log.warning("response isn't a parseable JSON");
  } on SocketException {
    log.warning("SocketException");
  }
  return jsonObject;
}

/// Gets the listing even if it's multi-page, and adds it to [entities].
Future getFullListing(String tech, DateTime from, DateTime to,
    http.Client client, List<Map<String, Object>> entities) async {
  // https://www.reddit.com/wiki/search#wiki_cloudsearch_syntax
  final cloudSearchQuery = "(and "
      "(or (field title '$tech') (field selftext '$tech')) "
      "timestamp:${from.millisecondsSinceEpoch ~/ 1000}"
      "..${to.millisecondsSinceEpoch ~/ 1000}"
      ")";

  log.info("query: $cloudSearchQuery");

  if (cloudSearchQuery.length > 512) {
    throw new ArgumentError("The q parameter of a reddit query cannot be over"
        "512 characters long (https://www.reddit.com/dev/api/#GET_search). It "
        "is currently: '$cloudSearchQuery' (which is "
        "${cloudSearchQuery.length} characters long)");
  }

  final queryParameters = {
    'q': cloudSearchQuery,
    't': 'all',
    // restrict_sr must be 'on' for temporary multireddits
    // https://www.reddit.com/r/help/comments/3muaic/how_to_use_cloudsearch_for_searching_multiple/cvi5yrn/
    'restrict_sr': 'on',
    'syntax': 'cloudsearch',
  };

  String afterToken;

  // ignore: literal_only_boolean_expressions
  while (true) {
    await new Future.delayed(new Duration(seconds: _random.nextInt(10)));
    if (afterToken != null) {
      queryParameters['after'] = afterToken;
    }
    final uri = Uri
        .parse("https://oauth.reddit.com/r/$subredditsInUrl/search")
        .replace(queryParameters: queryParameters);
    log.info(uri);
    final Map<String, dynamic> jsonObject = await getListingJson(client, uri);
    if (jsonObject == null || jsonObject['data'] == null) {
      log.warning(
          "getListingJson returned null or a JSON that doesn't contain data");
      log.info(jsonEncoder.convert(jsonObject));
      await new Future.delayed(new Duration(seconds: _random.nextInt(30)));
      log.info("re-authenticating");
      if (!await _auth(client)) {
        log.warning("ERROR: couldn't re-authenticate");
      }
      await new Future.delayed(new Duration(seconds: _random.nextInt(30)));
      continue;
    }
    entities.addAll(jsonObject['data']['children']);
    stdout.write(".");
    afterToken = jsonObject['data']['after'];
    if (afterToken == null) break;
  }
}

/// Updates [accessToken] by calling the Reddit OAuth API.
///
/// Equivalent to:
///
///     curl -u app_id:secret \
///         --data "grant_type=client_credentials" \
///         -A "some UA other than default" \
///         https://www.reddit.com/api/v1/access_token
Future<bool> _auth(http.Client client) async {
  final uri = Uri.parse(r"https://www.reddit.com/api/v1/access_token");
  final request = new http.Request("post", uri);
  request.headers[HttpHeaders.USER_AGENT] = userAgent;
  request.headers[HttpHeaders.AUTHORIZATION] =
      'Basic ${encodeAuth(clientId, appSecret)}';
  request.bodyFields = {'grant_type': 'client_credentials'};
  final response = await client.send(request);
  final json = await response.stream.bytesToString();
  Map jsonObject;
  try {
    jsonObject = JSON.decode(json);
  } on FormatException {
    log.warning("ERROR: non-JSON response in auth: $json");
  }
  if (jsonObject == null) {
    return false;
  }
  final newToken = jsonObject['access_token'];
  if (newToken == null) {
    log.warning("oauth response doesn't include access token");
    log.info(jsonEncoder.convert(jsonObject));
    return false;
  }
  accessToken = newToken;
  return true;
}

Future<String> _getListing(http.Client client, Uri uri) async {
  final request = new http.Request("get", uri);
  request.headers[HttpHeaders.USER_AGENT] = userAgent;
  request.headers[HttpHeaders.AUTHORIZATION] = "bearer $accessToken";
  // TODO: catch SocketException
  final response = await client.send(request);
  final json = await response.stream.bytesToString();
  return json;
}
