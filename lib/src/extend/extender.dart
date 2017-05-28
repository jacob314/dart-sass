// Copyright 2016 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:math' as math;

import 'package:source_span/source_span.dart';

import '../ast/css.dart';
import '../ast/selector.dart';
import '../ast/sass.dart';
import '../exception.dart';
import 'state.dart';
import 'functions.dart';

/// Tracks style rules and extensions, and applies the latter to the former.
class Extender {
  /// A map from all simple selectors in the stylesheet to the rules that
  /// contain them.
  ///
  /// This is used to find which rules an `@extend` applies to.
  final _selectors = <SimpleSelector, Set<CssStyleRule>>{};

  /// A map from all extended simple selectors to the sources of those
  /// extensions.
  final _extensions = <SimpleSelector, Map<SelectorList, ExtendState>>{};

  /// An expando from [CssStyleRule] to media query contexts.
  ///
  /// This tracks the contexts in which each style rule is defined. If a rule is
  /// defined at the top level, it doesn't have an entry.
  final _mediaContexts = new Expando<List<CssMediaQuery>>();

  /// An expando from [SimpleSelector]s to integers.
  ///
  /// This tracks the maximum specificity of the [ComplexSelector] that
  /// originally contained each [SimpleSelector]. This allows us to ensure that
  /// we don't trim any selectors that need to exist to satisfy the [second law
  /// of extend][].
  ///
  /// [second law of extend]: https://github.com/sass/sass/issues/324#issuecomment-4607184
  final _sourceSpecificity = new Expando<int>();

  /// An expando that tracks [ComplexSelector]s that were originally part of
  /// their component [SelectorList]s, as opposed to being added by `@extend`.
  ///
  /// This allows us to ensure that we do'nt trim any selectors that need to
  /// exist to satisfy the [first law of extend][].
  ///
  /// [first law of extend]: https://github.com/sass/sass/issues/324#issuecomment-4607184
  final _original = new Expando<bool>();

  /// Extends [selector] with [source] extender and [target] the extendee.
  ///
  /// This works as though `source {@extend target}` were written in
  /// the stylesheet.
  static SelectorList extend(
          SelectorList selector, SelectorList source, SimpleSelector target) =>
      new Extender()._extendList(
          selector,
          {
            target: {source: new ExtendState.oneOff()}
          },
          null);

  /// Returns a copy of [selector] with [source] replaced by [target].
  static SelectorList replace(
          SelectorList selector, SelectorList source, SimpleSelector target) =>
      new Extender()._extendList(
          selector,
          {
            target: {source: new ExtendState.oneOff()}
          },
          null,
          replace: true);

  /// Adds [selector] to this extender, associated with [span].
  ///
  /// Extends [selector] using any registered extensions, then returns an empty
  /// [CssStyleRule] with the resulting selector. If any more relevant
  /// extensions are added, the returned rule is automatically updated.
  ///
  /// The [mediaContext] is the media query context in which the selector was
  /// defined, or `null` if it was defined at the top level of the document.
  CssStyleRule addSelector(CssValue<SelectorList> selector, FileSpan span,
      [List<CssMediaQuery> mediaContext]) {
    for (var complex in selector.value.components) {
      _original[complex] = true;
    }

    if (_extensions.isNotEmpty) {
      try {
        selector = new CssValue(
            _extendList(selector.value, _extensions, mediaContext),
            selector.span);
      } on SassException catch (error) {
        throw new SassException(
            "From ${error.span.message('')}\n"
            "${error.message}",
            selector.span);
      }
    }
    var rule = new CssStyleRule(selector, span);
    if (mediaContext != null) _mediaContexts[rule] = mediaContext;
    _registerSelector(selector.value, rule);

    return rule;
  }

  /// Registers the [SimpleSelector]s in [list] to point to [rule] in
  /// [_selectors].
  void _registerSelector(SelectorList list, CssStyleRule rule) {
    for (var complex in list.components) {
      for (var component in complex.components) {
        if (component is CompoundSelector) {
          for (var simple in component.components) {
            _selectors.putIfAbsent(simple, () => new Set()).add(rule);

            if (simple is PseudoSelector && simple.selector != null) {
              _registerSelector(simple.selector, rule);
            }
          }
        }
      }
    }
  }

  /// Adds an extension to this extender.
  ///
  /// The [extender] is the selector for the style rule in which the extension
  /// is defined, and [target] is the selector passed to `@extend`. The [extend]
  /// provides the extend span and indicates whether the extension is optional.
  ///
  /// The [mediaContext] defines the media query context in which the extension
  /// is defined. It can only extend selectors within the same context. A `null`
  /// context indicates no media queries.
  void addExtension(
      SelectorList extender, SimpleSelector target, ExtendRule extend,
      [List<CssMediaQuery> mediaContext]) {
    var sources = _extensions.putIfAbsent(target, () => {});
    var existingState = sources[extender];
    if (existingState != null) {
      // If there's already an extend from [extender] to [target], we don't need
      // to re-run the extension. We may need to mark the extension as
      // mandatory, though.
      existingState.addSource(extend.span, mediaContext,
          optional: extend.isOptional);
      return;
    }

    var state =
        new ExtendState(extend.span, mediaContext, optional: extend.isOptional);
    sources[extender] = state;

    for (var complex in extender.components) {
      for (var component in complex.components) {
        if (component is CompoundSelector) {
          for (var simple in component.components) {
            _sourceSpecificity[simple] = complex.maxSpecificity;
          }
        }
      }
    }

    var rules = _selectors[target];
    if (rules == null) return;
    var extensions = {
      target: {extender: state}
    };
    for (var rule in rules) {
      try {
        rule.selector.value =
            _extendList(rule.selector.value, extensions, _mediaContexts[rule]);
      } on SassException catch (error) {
        throw new SassException(
            "From ${rule.selector.span.message('')}\n"
            "${error.message}",
            error.span);
      }

      _registerSelector(rule.selector.value, rule);
    }
  }

  /// Throws a [SassException] if any (non-optional) extensions failed to match
  /// any selectors.
  void finalize() {
    _extensions.forEach((target, sources) {
      sources.forEach((_, state) {
        if (state.isOptional || state.isUsed) return;
        throw new SassException(
            'The target selector was not found.\n'
            'Use "@extend $target !optional" to avoid this error.',
            state.span);
      });
    });
  }

  /// Extends [list] using [extensions].
  ///
  /// If [replace] is `true`, this doesn't preserve the original selectors.
  SelectorList _extendList(
      SelectorList list,
      Map<SimpleSelector, Map<SelectorList, ExtendState>> extensions,
      List<CssMediaQuery> mediaQueryContext,
      {bool replace: false}) {
    // This could be written more simply using [List.map], but we want to avoid
    // any allocations in the common case where no extends apply.
    List<List<ComplexSelector>> extended;
    for (var i = 0; i < list.components.length; i++) {
      var complex = list.components[i];
      var result = _extendComplex(complex, extensions, mediaQueryContext,
          replace: replace);
      if (result == null) {
        if (extended != null) extended.add([complex]);
      } else {
        extended ??= i == 0 ? [] : [list.components.sublist(0, i).toList()];
        extended.addAll(result);
      }
    }
    if (extended == null) return list;

    return new SelectorList(
        _trim(extended).where((complex) => complex != null));
  }

  /// Extends [complex] using [extensions], and returns the contents of a
  /// [SelectorList].
  ///
  /// If [replace] is `true`, this doesn't preserve the original selectors.
  List<List<ComplexSelector>> _extendComplex(
      ComplexSelector complex,
      Map<SimpleSelector, Map<SelectorList, ExtendState>> extensions,
      List<CssMediaQuery> mediaQueryContext,
      {bool replace: false}) {
    // This could be written more simply using [List.map], but we want to avoid
    // any allocations in the common case where no extends apply.
    var changed = false;
    List<List<ComplexSelector>> extendedNotExpanded;
    for (var i = 0; i < complex.components.length; i++) {
      var component = complex.components[i];
      if (component is CompoundSelector) {
        var extended = _extendCompound(component, extensions, mediaQueryContext,
            replace: replace);
        if (extended == null) {
          if (changed) {
            extendedNotExpanded.add([
              new ComplexSelector([component])
            ]);
          }
        } else {
          if (!changed) {
            extendedNotExpanded = complex.components
                .take(i)
                .map((component) => [
                      new ComplexSelector([component],
                          lineBreak: complex.lineBreak)
                    ])
                .toList();
          }
          changed = true;
          extendedNotExpanded.add(extended);
        }
      } else {
        if (changed) {
          extendedNotExpanded.add([
            new ComplexSelector([component])
          ]);
        }
      }
    }
    if (!changed) return null;

    var first = true;
    return paths(extendedNotExpanded).map((path) {
      return weave(path.map((complex) => complex.components).toList())
          .map((components) {
        var outputComplex = new ComplexSelector(components,
            lineBreak: complex.lineBreak ||
                path.any((inputComplex) => inputComplex.lineBreak));

        // Make sure that copies of [complex] retain their status as "original"
        // selectors. This includes selectors that are modified because a :not()
        // was extended into.
        if (first && _original[complex] != null) {
          _original[outputComplex] = true;
        }
        first = false;

        return outputComplex;
      }).toList();
    }).toList();
  }

  /// Extends [compound] using [extensions], and returns the contents of a
  /// [SelectorList].
  ///
  /// If [replace] is `true`, this doesn't preserve the original selectors.
  List<ComplexSelector> _extendCompound(
      CompoundSelector compound,
      Map<SimpleSelector, Map<SelectorList, ExtendState>> extensions,
      List<CssMediaQuery> mediaQueryContext,
      {bool replace: false}) {
    var original = compound;

    List<ComplexSelector> extended;
    for (var i = 0; i < compound.components.length; i++) {
      var simple = compound.components[i];

      var extendedPseudo = simple is PseudoSelector && simple.selector != null
          ? _extendPseudo(simple, extensions, mediaQueryContext,
              replace: replace)
          : null;

      if (extendedPseudo != null) {
        var simples = new List<SimpleSelector>(
            compound.components.length - 1 + extendedPseudo.length);
        simples.setRange(0, i, compound.components);
        simples.setRange(i, i + extendedPseudo.length, extendedPseudo);
        simples.setRange(i + extendedPseudo.length, simples.length,
            compound.components, i + 1);
        original = new CompoundSelector(simples);
      }

      var sources = extensions[simple];
      if (sources == null) continue;

      var compoundWithoutSimple =
          new List<SimpleSelector>(compound.components.length - 1);
      compoundWithoutSimple.setRange(0, i, compound.components);
      compoundWithoutSimple.setRange(
          i, compound.components.length - 1, compound.components, i + 1);
      sources.forEach((extender, state) {
        for (var complex in extender.components) {
          var extenderBase = complex.components.last as CompoundSelector;
          var unified = compoundWithoutSimple.isEmpty
              ? extenderBase
              : unifyCompound(extenderBase.components, compoundWithoutSimple);
          if (unified == null) continue;

          state.assertCompatibleMediaContext(mediaQueryContext);

          extended ??= replace
              ? []
              : [
                  new ComplexSelector([compound])
                ];

          var newComplex = new ComplexSelector(
              complex.components
                  .sublist(0, complex.components.length - 1)
                  .toList()
                    ..add(unified),
              lineBreak: complex.lineBreak);
          _addSourceSpecificity(
              newComplex,
              math.max(
                  _sourceSpecificityFor(compound), complex.maxSpecificity));
          extended.add(newComplex);
          state.isUsed = true;
        }
      });
    }

    if (extended == null) {
      return identical(original, compound)
          ? null
          : [
              new ComplexSelector([original])
            ];
    } else if (!identical(original, compound)) {
      if (replace) {
        extended.insert(0, new ComplexSelector([original]));
      } else {
        extended[0] = new ComplexSelector([original]);
      }
    }

    return extended;
  }

  /// Extends [pseudo] using [extensions], and returns a list of resulting
  /// pseudo selectors.
  ///
  /// If [replace] is `true`, this doesn't preserve the original selectors.
  List<PseudoSelector> _extendPseudo(
      PseudoSelector pseudo,
      Map<SimpleSelector, Map<SelectorList, ExtendState>> extensions,
      List<CssMediaQuery> mediaQueryContext,
      {bool replace: false}) {
    var extended = _extendList(pseudo.selector, extensions, mediaQueryContext,
        replace: replace);
    if (identical(extended, pseudo.selector)) return null;

    // TODO: what do we do about placeholders in the selector? If we just
    // eliminate them here, what happens to future extends?

    // For `:not()`, we usually want to get rid of any complex selectors because
    // that will cause the selector to fail to parse on all browsers at time of
    // writing. We can keep them if either the original selector had a complex
    // selector, or the result of extending has only complex selectors, because
    // either way we aren't breaking anything that isn't already broken.
    Iterable<ComplexSelector> complexes = extended.components;
    if (pseudo.normalizedName == "not" &&
        !pseudo.selector.components
            .any((complex) => complex.components.length > 1) &&
        extended.components.any((complex) => complex.components.length == 1)) {
      complexes = extended.components
          .where((complex) => complex.components.length <= 1);
    }

    complexes = complexes.expand((complex) {
      if (complex.components.length != 1) return [complex];
      if (complex.components.first is! CompoundSelector) return [complex];
      var compound = complex.components.first as CompoundSelector;
      if (compound.components.length != 1) return [complex];
      if (compound.components.first is! PseudoSelector) return [complex];
      var innerPseudo = compound.components.first as PseudoSelector;
      if (innerPseudo.selector == null) return [complex];

      switch (pseudo.normalizedName) {
        case 'not':
          // In theory, if there's a `:not` nested within another `:not`, the
          // inner `:not`'s contents should be unified with the return value.
          // For example, if `:not(.foo)` extends `.bar`, `:not(.bar)` should
          // become `.foo:not(.bar)`. However, this is a narrow edge case and
          // supporting it properly would make this code and the code calling it
          // a lot more complicated, so it's not supported for now.
          if (innerPseudo.normalizedName != 'matches') return [];
          return innerPseudo.selector.components;

        case 'matches':
        case 'any':
        case 'current':
        case 'nth-child':
        case 'nth-last-child':
          // As above, we could theoretically support :not within :matches, but
          // doing so would require this method and its callers to handle much
          // more complex cases that likely aren't worth the pain.
          if (innerPseudo.name != pseudo.name) return [];
          if (innerPseudo.argument != pseudo.argument) return [];
          return innerPseudo.selector.components;

        case 'has':
        case 'host':
        case 'host-context':
          // We can't expand nested selectors here, because each layer adds an
          // additional layer of semantics. For example, `:has(:has(img))`
          // doesn't match `<div><img></div>` but `:has(img)` does.
          return [complex];

        default:
          return [];
      }
    });

    // Older browsers support `:not`, but only with a single complex selector.
    // In order to support those browsers, we break up the contents of a `:not`
    // unless it originally contained a selector list.
    if (pseudo.normalizedName == 'not' &&
        pseudo.selector.components.length == 1) {
      return complexes
          .map((complex) => pseudo.withSelector(new SelectorList([complex])))
          .toList();
    } else {
      return [pseudo.withSelector(new SelectorList(complexes))];
    }
  }

  // Removes redundant selectors from [lists].
  //
  // Each individual list in [lists] is assumed to have no redundancy within
  // itself. A selector is only removed if it's redundant with a selector in
  // another list. "Redundant" here means that one selector is a superselector
  // of the other. The more specific selector is removed.
  List<ComplexSelector> _trim(List<List<ComplexSelector>> lists) {
    // Avoid truly horrific quadratic behavior.
    //
    // TODO(nweiz): I think there may be a way to get perfect trimming without
    // going quadratic by building some sort of trie-like data structure that
    // can be used to look up superselectors.
    if (lists.length > 100) {
      return lists.expand((selectors) => selectors).toList();
    }

    // This is n² on the sequences, but only comparing between separate
    // sequences should limit the quadratic behavior.
    var result = <ComplexSelector>[];
    for (var i = 0; i < lists.length; i++) {
      for (var complex1 in lists[i]) {
        if (_original[complex1] != null) {
          result.add(complex1);
          continue;
        }

        // The maximum specificity of the sources that caused [complex1] to be
        // generated. In order for [complex1] to be removed, there must be
        // another selector that's a superselector of it *and* that has
        // specificity greater or equal to this.
        var maxSpecificity = 0;
        for (var component in complex1.components) {
          if (component is CompoundSelector) {
            for (var simple in component.components) {
              maxSpecificity =
                  math.max(maxSpecificity, _sourceSpecificity[simple] ?? 0);
            }
          }
        }

        // Look in [result] rather than [lists] for selectors before [i]. This
        // ensures that we aren't comparing against a selector that's already
        // been trimmed, and thus that if there are two identical selectors only
        // one is trimmed.
        if (result.any((complex2) =>
            complex2.minSpecificity >= maxSpecificity &&
            complex2.isSuperselector(complex1))) {
          continue;
        }

        // We intentionally don't compare [complex1] against other selectors in
        // `lists[i]`, since they come from the same source.
        if (lists.skip(i + 1).any((list) => list.any((complex2) =>
            complex2.minSpecificity >= maxSpecificity &&
            complex2.isSuperselector(complex1)))) {
          continue;
        }

        result.add(complex1);
      }
    }

    return result;
  }

  /// Adds [specificity] to the [_sourceSpecificity] for all simple selectors in [complex].
  void _addSourceSpecificity(ComplexSelector complex, int specificity) {
    if (specificity == 0) return;
    for (var component in complex.components) {
      if (component is CompoundSelector) {
        for (var simple in component.components) {
          _sourceSpecificity[simple] =
              math.max(_sourceSpecificity[simple] ?? 0, specificity);
        }
      }
    }
  }

  /// Returns the maximum specificity for sources that went into producing
  /// [compound].
  int _sourceSpecificityFor(CompoundSelector compound) {
    var specificity = 0;
    for (var simple in compound.components) {
      specificity = math.max(specificity, _sourceSpecificity[simple] ?? 0);
    }
    return specificity;
  }
}
