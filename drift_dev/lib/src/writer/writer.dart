import 'package:drift/drift.dart';
import 'package:path/path.dart' show url;
import 'package:recase/recase.dart';
import 'package:sqlparser/sqlparser.dart' as sql;

import '../analysis/options.dart';
import '../analysis/results/results.dart';
import 'import_manager.dart';
import 'queries/sql_writer.dart';

/// Manages a tree structure which we use to generate code.
///
/// Each leaf in the tree is a [StringBuffer] that contains some code. A
/// [Scope] is a non-leaf node in the tree. Why are we doing this? Sometimes,
/// we're in the middle of generating the implementation of a method and we
/// realize we need to introduce another top-level class! When passing a single
/// [StringBuffer] to the generators that will get ugly to manage, but when
/// passing a [Scope] we will always be able to write code in a parent scope.
class Writer extends _NodeOrWriter {
  late final Scope _root;
  late final TextEmitter _header;
  late final TextEmitter _imports;

  final DriftOptions options;
  final GenerationOptions generationOptions;

  TextEmitter get header => _header;
  TextEmitter get imports => _imports;

  @override
  Writer get writer => this;

  Writer(this.options, {required this.generationOptions}) {
    _root = Scope(parent: null, writer: this);
    _header = leaf();
    _imports = leaf();
  }

  /// Returns the code generated by this [Writer].
  String writeGenerated() => _leafNodes(_root).join();

  Iterable<StringBuffer> _leafNodes(Scope scope) sync* {
    for (final child in scope._children) {
      if (child is TextEmitter) {
        yield child.buffer;
      } else if (child is Scope) {
        yield* _leafNodes(child);
      }
    }
  }

  Scope child() => _root.child();
  TextEmitter leaf() => _root.leaf();
}

abstract class _NodeOrWriter {
  Writer get writer;

  AnnotatedDartCode generatedElement(DriftElement element, String dartName) {
    return AnnotatedDartCode.build(
        (b) => b.addGeneratedElement(element, dartName));
  }

  AnnotatedDartCode modularAccessor(Uri driftFile) {
    final id = DriftElementId(driftFile, '(file)');

    return AnnotatedDartCode([
      DartTopLevelSymbol(
          ReCase(url.basename(driftFile.path)).pascalCase, id.modularImportUri),
    ]);
  }

  AnnotatedDartCode companionType(DriftTable table) {
    final baseName = writer.options.useDataClassNameForCompanions
        ? table.nameOfRowClass
        : table.baseDartName;

    return generatedElement(table, '${baseName}Companion');
  }

  AnnotatedDartCode entityInfoType(DriftElementWithResultSet element) {
    return generatedElement(element, element.entityInfoName);
  }

  AnnotatedDartCode rowType(DriftElementWithResultSet element) {
    return AnnotatedDartCode.build((b) => b.addElementRowType(element));
  }

  AnnotatedDartCode rowClass(DriftElementWithResultSet element) {
    final existing = element.existingRowClass;
    if (existing != null) {
      return existing.targetClass ??
          (throw StateError('$element does not have a row class'));
    } else {
      return generatedElement(element, element.nameOfRowClass);
    }
  }

  /// Returns a Dart expression evaluating to the [converter].
  AnnotatedDartCode readConverter(AppliedTypeConverter converter,
      {bool forNullable = false}) {
    if (converter.owningColumn == null) {
      // Type converters applied to individual columns in the result set of a
      // `SELECT` query don't have an owning table. We instead write the
      // expression here.
      return AnnotatedDartCode.build((b) {
        final implicitlyNullable =
            converter.canBeSkippedForNulls && forNullable;

        if (implicitlyNullable) {
          b.addSymbol('NullAwareTypeConverter.wrap(', AnnotatedDartCode.drift);
        }

        b.addCode(converter.expression);

        if (implicitlyNullable) {
          b.addText(')');
        }
      });
    } else {
      final fieldName = forNullable && converter.canBeSkippedForNulls
          ? converter.nullableFieldName
          : converter.fieldName;

      return AnnotatedDartCode([
        ...entityInfoType(converter.owningColumn!.owner).elements,
        '.$fieldName',
      ]);
    }
  }

  /// A suitable typename to store an instance of the type converter used here.
  AnnotatedDartCode converterType(AppliedTypeConverter converter,
      {bool makeNullable = false}) {
    // Write something like `TypeConverter<MyFancyObject, String>`
    return AnnotatedDartCode.build((b) {
      var sqlDartType = dartTypeNames[converter.sqlType]!;
      final className = converter.alsoAppliesToJsonConversion
          ? 'JsonTypeConverter2'
          : 'TypeConverter';

      b
        ..addSymbol(className, AnnotatedDartCode.drift)
        ..addText('<')
        ..addDartType(converter.dartType)
        ..questionMarkIfNullable(makeNullable)
        ..addText(',')
        ..addTopLevel(sqlDartType)
        ..questionMarkIfNullable(makeNullable || converter.sqlTypeIsNullable);

      if (converter.alsoAppliesToJsonConversion) {
        b
          ..addText(',')
          ..addDartType(converter.jsonType!)
          ..questionMarkIfNullable(makeNullable);
      }

      b.addText('>');
    });
  }

  AnnotatedDartCode dartType(HasType hasType) {
    return AnnotatedDartCode.build((b) => b.addDriftType(hasType));
  }

  /// The Dart type that matches the type of this column, ignoring type
  /// converters.
  ///
  /// This is the same as [dartType] but without custom types.
  AnnotatedDartCode variableTypeCode(HasType type, {bool? nullable}) {
    if (type.isArray) {
      final inner = innerColumnType(type, nullable: nullable ?? type.nullable);
      return AnnotatedDartCode([
        DartTopLevelSymbol.list,
        '<',
        ...inner.elements,
        '>',
      ]);
    } else {
      return innerColumnType(type, nullable: nullable ?? type.nullable);
    }
  }

  /// The raw Dart type for this column, taking its nullability only from the
  /// [nullable] parameter.
  ///
  /// This type does not respect type converters or arrays.
  AnnotatedDartCode innerColumnType(HasType type, {bool nullable = false}) {
    return AnnotatedDartCode([
      dartTypeNames[type.sqlType],
      if (nullable) '?',
    ]);
  }

  String refUri(Uri definition, String element) {
    final prefix =
        writer.generationOptions.imports.prefixFor(definition, element);

    if (prefix == null) {
      return element;
    } else {
      return '$prefix.$element';
    }
  }

  /// References a top-level symbol exposed by the core `package:drift/drift.dart`
  /// library.
  String drift(String element) {
    return refUri(AnnotatedDartCode.drift, element);
  }

  String dartCode(AnnotatedDartCode code) {
    final buffer = StringBuffer();

    for (final lexeme in code.elements) {
      if (lexeme is DartTopLevelSymbol) {
        final uri = lexeme.importUri;

        if (uri != null) {
          buffer.write(refUri(uri, lexeme.lexeme));
        } else {
          buffer.write(lexeme.lexeme);
        }
      } else {
        buffer.write(lexeme);
      }
    }

    return buffer.toString();
  }

  String sqlCode(sql.AstNode node, SqlDialect dialect) {
    return SqlWriter(writer.options, dialect: dialect, escapeForDart: false)
        .writeSql(node);
  }

  /// Builds a Dart expression writing the [node] into a Dart string.
  ///
  /// If the code for [node] depends on the dialect, the code returned evaluates
  /// to a `Map<SqlDialect, String>`. Otherwise, the code is a direct string
  /// literal.
  ///
  /// The boolean component in the record describes whether the code will be
  /// dialect specific.
  (String, bool) sqlByDialect(sql.AstNode node) {
    final dialects = writer.options.supportedDialects;

    if (dialects.length == 1) {
      return (
        SqlWriter(writer.options, dialect: dialects.single)
            .writeNodeIntoStringLiteral(node),
        false
      );
    }

    final buffer = StringBuffer();
    _writeSqlByDialectMap(node, buffer);
    return (buffer.toString(), true);
  }

  void _writeSqlByDialectMap(sql.AstNode node, StringBuffer buffer) {
    buffer.write('{');

    for (final dialect in writer.options.supportedDialects) {
      buffer
        ..write(drift('SqlDialect'))
        ..write(".${dialect.name}: '");

      SqlWriter(writer.options, dialect: dialect, buffer: buffer)
          .writeSql(node);

      buffer.writeln("',");
    }

    buffer.write('}');
  }
}

abstract class _Node extends _NodeOrWriter {
  final Scope? parent;

  _Node(this.parent);
}

/// A single lexical scope that is a part of a [Writer].
///
/// The reason we use scopes to write generated code is that some implementation
/// methods might need to introduce additional classes when written. When we can
/// create a new text leaf of the root node, this can be done very easily. When
/// we just pass a single [StringBuffer] around, this is annoying to manage.
class Scope extends _Node {
  final List<_Node> _children = [];
  @override
  final Writer writer;

  /// An arbitrary counter.
  ///
  /// This can be used to generated methods which must have a unique name-
  int counter = 0;

  /// The set of names already used in this scope. Used by methods like
  /// [getNonConflictingName] to prevent name collisions.
  final Set<String> _usedNames = {};

  Scope({required Scope? parent, Writer? writer})
      : writer = writer ?? parent!.writer,
        super(parent);

  DriftOptions get options => writer.options;

  GenerationOptions get generationOptions => writer.generationOptions;

  Scope get root {
    var found = this;
    while (found.parent != null) {
      found = found.parent!;
    }
    return found;
  }

  Scope child() {
    final child = Scope(parent: this);
    _children.add(child);
    return child;
  }

  TextEmitter leaf() {
    final child = TextEmitter(this);
    _children.add(child);
    return child;
  }

  /// Reserve a collection of names in this scope. See [getNonConflictingName]
  /// for more information.
  void reserveNames(Iterable<String> names) {
    _usedNames.addAll(names);
  }

  /// Returns a variation of [name] that does not conflict with any names
  /// already in use in this [Scope].
  ///
  /// If [name] does not conflict with any existing names then it is returned
  /// unmodified. If a conflict is detected then [name] is repeatedly passed to
  /// [modify] until the result no longer conflicts. Each result returned from
  /// this method is recorded in an internal set, so subsequent calls with the
  /// same name will produce a different, non-conflicting result.
  String getNonConflictingName(String name, String Function(String) modify) {
    while (_usedNames.contains(name)) {
      name = modify(name);
    }
    _usedNames.add(name);
    return name;
  }
}

class TextEmitter extends _Node {
  final StringBuffer buffer = StringBuffer();
  @override
  final Writer writer;

  TextEmitter(Scope super.parent) : writer = parent.writer;

  void write(Object? object) => buffer.write(object);
  void writeln(Object? object) => buffer.writeln(object);

  void writeUriRef(Uri definition, String element) {
    return write(refUri(definition, element));
  }

  void writeDriftRef(String element) => write(drift(element));

  void writeDart(AnnotatedDartCode code) => write(dartCode(code));

  void writeSql(sql.AstNode node,
      {required SqlDialect dialect, bool escapeForDartString = true}) {
    SqlWriter(
      writer.options,
      dialect: dialect,
      escapeForDart: escapeForDartString,
      buffer: buffer,
    ).writeSql(node);
  }

  void writeSqlByDialectMap(sql.AstNode node) {
    _writeSqlByDialectMap(node, buffer);
  }
}

/// Options that are specific to code-generation.
class GenerationOptions {
  /// Whether we're generating code to verify schema migrations.
  ///
  /// When non-null, we're generating from a schema snapshot instead of from
  /// source.
  final int? forSchema;

  /// Whether data classes should be generated.
  final bool writeDataClasses;

  /// Whether companions should be generated.
  final bool writeCompanions;

  /// Whether multiple files are generated, instead of just generating one file
  /// for each database.
  final bool isModular;

  final ImportManager imports;

  const GenerationOptions({
    required this.imports,
    this.forSchema,
    this.writeDataClasses = true,
    this.writeCompanions = true,
    this.isModular = false,
  });

  /// Whether, instead of generating the full database code, we're only
  /// generating a subset needed for schema verification.
  bool get isGeneratingForSchema => forSchema != null;
}

extension WriterUtilsForOptions on DriftOptions {
  String get fieldModifier => generateMutableClasses ? '' : 'final';
}

/// Adds an `this.` prefix is the [dartGetterName] is in [locals].
String thisIfNeeded(String getter, Set<String> locals) {
  if (locals.contains(getter)) {
    return 'this.$getter';
  }

  return getter;
}

extension on AnnotatedDartCodeBuilder {
  void questionMarkIfNullable(bool nullable) {
    if (nullable) addText('?');
  }
}
