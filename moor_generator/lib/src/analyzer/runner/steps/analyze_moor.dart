part of '../steps.dart';

class AnalyzeMoorStep extends AnalyzingStep {
  AnalyzeMoorStep(Task task, FoundFile file) : super(task, file);

  void analyze() {
    if (file.currentResult == null) {
      // Error during parsing, ignore.
      return;
    }

    final parseResult = file.currentResult as ParsedMoorFile;

    final transitiveImports =
        task.crawlImports(parseResult.resolvedImports.values).toList();

    final availableTables = _availableTables(transitiveImports)
        .followedBy(parseResult.declaredTables)
        .toList();

    final availableViews = _availableViews(transitiveImports)
        .followedBy(parseResult.declaredViews)
        .toList();

    final parser =
        SqlAnalyzer(this, availableTables, availableViews, parseResult.queries)
          ..parse();

    EntityHandler(this, parseResult, availableTables, availableViews).handle();

    parseResult.resolvedQueries = parser.foundQueries;
  }
}
