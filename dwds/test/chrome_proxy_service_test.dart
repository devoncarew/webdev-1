// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dwds/src/connections/debug_connection.dart';
import 'package:dwds/src/loaders/strategy.dart';
import 'package:dwds/src/services/chrome_proxy_service.dart';
import 'package:dwds/src/utilities/dart_uri.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:pedantic/pedantic.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

import 'fixtures/context.dart';

final context = TestContext();

ChromeProxyService get service =>
    fetchChromeProxyService(context.debugConnection);

WipConnection get tabConnection => context.tabConnection;

void main() {
  group('shared context', () {
    setUpAll(() async {
      await context.setUp();
    });

    tearDownAll(() async {
      await context.tearDown();
    });

    test('client name', () async {
      expect(() => service.getClientName(), throwsUnimplementedError);
      expect(() => service.setClientName('foo'), throwsUnimplementedError);
    });

    group('breakpoints', () {
      VM vm;
      Isolate isolate;
      ScriptList scripts;
      ScriptRef mainScript;

      setUp(() async {
        vm = await fetchChromeProxyService(context.debugConnection).getVM();
        isolate = await fetchChromeProxyService(context.debugConnection)
            .getIsolate(vm.isolates.first.id);
        scripts = await fetchChromeProxyService(context.debugConnection)
            .getScripts(isolate.id);
        mainScript = scripts.scripts
            .firstWhere((each) => each.uri.contains('main.dart'));
      });

      test('addBreakpoint', () async {
        // TODO: Much more testing.
        var line = await context.findBreakpointLine(
            'printHelloWorld', isolate.id, mainScript);
        var firstBp =
            await service.addBreakpoint(isolate.id, mainScript.id, line);
        expect(firstBp, isNotNull);
        expect(firstBp.id, isNotNull);

        // Set another breakpoint at the same place - should get the original.
        var secondBp =
            await service.addBreakpoint(isolate.id, mainScript.id, line);
        expect(secondBp.id, firstBp.id);

        // Remove breakpoint so it doesn't impact other tests.
        await service.removeBreakpoint(isolate.id, firstBp.id);
        // We shouldn't be able to remove it again.
        expect(() => service.removeBreakpoint(isolate.id, secondBp.id),
            throwsArgumentError);
      });

      test('addBreakpoint in nonsense location throws', () async {
        expect(service.addBreakpoint(isolate.id, mainScript.id, 200000),
            throwsA(predicate((e) => e is RPCError && e.code == 102)));
      });

      test('addBreakpoint on a part file', () async {
        var partScript = scripts.scripts
            .firstWhere((script) => script.uri.contains('part.dart'));
        var bp = await service.addBreakpoint(isolate.id, partScript.id, 10);
        // Remove breakpoint so it doesn't impact other tests.
        await service.removeBreakpoint(isolate.id, bp.id);
        expect(bp.id, isNotNull);
      });

      test('addBreakpointAtEntry', () {
        expect(() => service.addBreakpointAtEntry(null, null),
            throwsUnimplementedError);
      });

      test('addBreakpointWithScriptUri', () async {
        var line = await context.findBreakpointLine(
            'printHelloWorld', isolate.id, mainScript);
        var bp = await service.addBreakpointWithScriptUri(
            isolate.id, mainScript.uri, line);
        // Remove breakpoint so it doesn't impact other tests.
        await service.removeBreakpoint(isolate.id, bp.id);
        expect(bp.id, isNotNull);
      });

      test('addBreakpointWithScriptUri absolute file URI', () async {
        var current = context.workingDirectory;
        var _test = path.join(path.dirname(current), '_test');
        var scriptPath = Uri.parse(mainScript.uri).path.substring(1);
        var fullPath = path.join(_test, scriptPath);
        var fileUri = Uri.file(fullPath);
        var line = await context.findBreakpointLine(
            'printHelloWorld', isolate.id, mainScript);
        var bp = await service.addBreakpointWithScriptUri(
            isolate.id, '$fileUri', line);
        // Remove breakpoint so it doesn't impact other tests.
        await service.removeBreakpoint(isolate.id, bp.id);
        expect(bp.id, isNotNull);
      });

      test('removeBreakpoint null arguments', () {
        expect(() => service.removeBreakpoint(null, null), throwsArgumentError);
      });

      test("removeBreakpoint doesn't exist", () {
        expect(() => service.removeBreakpoint(isolate.id, '1234'),
            throwsArgumentError);
      });
      test('add and remove breakpoint', () async {
        var line = await context.findBreakpointLine(
            'printHelloWorld', isolate.id, mainScript);
        var bp = await service.addBreakpoint(isolate.id, mainScript.id, line);
        expect(isolate.breakpoints, [bp]);
        await service.removeBreakpoint(isolate.id, bp.id);
        expect(isolate.breakpoints, isEmpty);
      });
    });

    group('callServiceExtension', () {
      test('success', () async {
        var serviceMethod = 'ext.test.callServiceExtension';
        await tabConnection.runtime
            .evaluate('registerExtension("$serviceMethod");');

        // The non-string keys/values get auto json-encoded to match the vm
        // behavior.
        var args = {
          'bool': true,
          'list': [1, '2', 3],
          'map': {'foo': 'bar'},
          'num': 1.0,
          'string': 'hello',
          1: 2,
          false: true,
        };

        var result =
            await service.callServiceExtension(serviceMethod, args: args);
        expect(
            result.json,
            args.map((k, v) => MapEntry(k is String ? k : jsonEncode(k),
                v is String ? v : jsonEncode(v))));
      }, onPlatform: {
        'windows': const Skip('https://github.com/dart-lang/webdev/issues/711'),
      });

      test('failure', () async {
        var serviceMethod = 'ext.test.callServiceExtensionWithError';
        await tabConnection.runtime
            .evaluate('registerExtensionWithError("$serviceMethod");');

        var errorDetails = {'intentional': 'error'};
        expect(
            service.callServiceExtension(serviceMethod, args: {
              'code': '-32001',
              'details': jsonEncode(errorDetails),
            }),
            throwsA(predicate((error) =>
                error is RPCError &&
                error.code == -32001 &&
                error.details == jsonEncode(errorDetails))));
      }, onPlatform: {
        'windows': const Skip('https://github.com/dart-lang/webdev/issues/711'),
      });
    });

    test('clearVMTimeline', () {
      expect(() => service.clearVMTimeline(), throwsUnimplementedError);
    });

    test('clearVMTimeline', () {
      expect(() => service.clearVMTimeline(), throwsUnimplementedError);
    });

    test('clearVMTimeline', () {
      expect(() => service.clearVMTimeline(), throwsUnimplementedError);
    });

    group('evaluate', () {
      Isolate isolate;
      setUpAll(() async {
        var vm = await service.getVM();
        isolate = await service.getIsolate(vm.isolates.first.id);
      });

      group('top level methods', () {
        test('can return strings', () async {
          expect(
              await service.evaluate(
                  isolate.id, isolate.rootLib.id, "helloString('world')"),
              const TypeMatcher<InstanceRef>().having(
                  (instance) => instance.valueAsString, 'value', 'world'));
        });

        test('can return bools', () async {
          expect(
              await service.evaluate(
                  isolate.id, isolate.rootLib.id, 'helloBool(true)'),
              const TypeMatcher<InstanceRef>().having(
                  (instance) => instance.valueAsString,
                  'valueAsString',
                  'true'));
          expect(
              await service.evaluate(
                  isolate.id, isolate.rootLib.id, 'helloBool(false)'),
              const TypeMatcher<InstanceRef>().having(
                  (instance) => instance.valueAsString,
                  'valueAsString',
                  'false'));
        });

        test('can return nums', () async {
          expect(
              await service.evaluate(
                  isolate.id, isolate.rootLib.id, 'helloNum(42.0)'),
              const TypeMatcher<InstanceRef>().having(
                  (instance) => instance.valueAsString, 'valueAsString', '42'));
          expect(
              await service.evaluate(
                  isolate.id, isolate.rootLib.id, 'helloNum(42.2)'),
              const TypeMatcher<InstanceRef>().having(
                  (instance) => instance.valueAsString,
                  'valueAsString',
                  '42.2'));
        });

        test('can return objects with ids', () async {
          var object = await service.evaluate(
              isolate.id, isolate.rootLib.id, 'createObject("cool")');
          expect(
              object,
              const TypeMatcher<InstanceRef>()
                  .having((instance) => instance.id, 'id', isNotNull));
          // TODO(jakemac): Add tests for the ClassRef once we create one,
          // https://github.com/dart-lang/sdk/issues/36771.
        });

        group('with provided scope', () {
          Future<InstanceRef> createRemoteObject(String message) async {
            return await service.evaluate(
                    isolate.id, isolate.rootLib.id, 'createObject("$message")')
                as InstanceRef;
          }

          test('single scope object', () async {
            var instance = await createRemoteObject('A');
            var result = await service.evaluate(
                isolate.id, isolate.rootLib.id, 'messageFor(arg1)',
                scope: {'arg1': instance.id});
            expect(
                result,
                const TypeMatcher<InstanceRef>().having(
                    (instance) => instance.valueAsString,
                    'valueAsString',
                    'A'));
          });

          test('multiple scope objects', () async {
            var instance1 = await createRemoteObject('A');
            var instance2 = await createRemoteObject('B');
            var result = await service.evaluate(
                isolate.id, isolate.rootLib.id, 'messagesCombined(arg1, arg2)',
                scope: {'arg1': instance1.id, 'arg2': instance2.id});
            expect(
                result,
                const TypeMatcher<InstanceRef>().having(
                    (instance) => instance.valueAsString,
                    'valueAsString',
                    'AB'));
          });
        });
      });
    });

    test('evaluateInFrame', () {
      expect(() => service.evaluateInFrame(null, null, null),
          throwsUnimplementedError);
    });

    test('getAllocationProfile', () {
      expect(
          () => service.getAllocationProfile(null), throwsUnimplementedError);
    });

    test('getClassList', () {
      expect(() => service.getClassList(null), throwsUnimplementedError);
    });

    test('getFlagList', () async {
      expect(await service.getFlagList(), isA<FlagList>());
    });

    test('getInstances', () {
      expect(() => service.getInstances(null, null, null),
          throwsUnimplementedError);
    });

    group('getIsolate', () {
      test('works for existing isolates', () async {
        var vm = await service.getVM();
        var result = await service.getIsolate(vm.isolates.first.id);
        expect(result, const TypeMatcher<Isolate>());
        var isolate = result;
        expect(isolate.name, contains(context.appUrl));
        // TODO: library names change with kernel dart-lang/sdk#36736
        expect(isolate.rootLib.uri, endsWith('main.dart'));

        expect(
            isolate.libraries,
            containsAll([
              _libRef('dart:core'),
              _libRef('dart:html'),
              _libRef('package:path/path.dart'),
              // TODO: library names change with kernel dart-lang/sdk#36736
              _libRef(endsWith('main.dart')),
            ]));
        expect(isolate.extensionRPCs, contains('ext.hello_world.existing'));
      });

      test('throws for invalid ids', () async {
        expect(service.getIsolate('bad'), throwsArgumentError);
      });
    });

    group('getObject', () {
      Isolate isolate;
      Library rootLibrary;

      setUpAll(() async {
        var vm = await service.getVM();
        isolate = await service.getIsolate(vm.isolates.first.id);
        rootLibrary =
            await service.getObject(isolate.id, isolate.rootLib.id) as Library;
      });

      test('Libraries', () async {
        expect(rootLibrary, isNotNull);
        // TODO: library names change with kernel dart-lang/sdk#36736
        expect(rootLibrary.uri, endsWith('main.dart'));
        expect(rootLibrary.classes, hasLength(1));
        var testClass = rootLibrary.classes.first;
        expect(testClass.name, 'MyTestClass');
      });

      test('Classes', () async {
        var testClass = await service.getObject(
            isolate.id, rootLibrary.classes.first.id) as Class;

        expect(
            testClass.functions,
            unorderedEquals([
              predicate((FuncRef f) => f.name == 'hello' && !f.isStatic),
            ]));
        expect(
            testClass.fields,
            unorderedEquals([
              predicate((FieldRef f) =>
                  f.name == 'message' &&
                  f.declaredType != null &&
                  !f.isStatic &&
                  !f.isConst &&
                  f.isFinal),
              predicate((FieldRef f) =>
                  f.name == 'notFinal' &&
                  f.declaredType != null &&
                  !f.isStatic &&
                  !f.isConst &&
                  !f.isFinal),
            ]));
      });

      test('String', () async {
        var worldRef = await service.evaluate(
                isolate.id, isolate.rootLib.id, "helloString('world')")
            as InstanceRef;
        var world =
            await service.getObject(isolate.id, worldRef.id) as Instance;
        expect(world.valueAsString, 'world');
      });

      test('Strings with offset', () async {
        var worldRef = await service.evaluate(
                isolate.id, isolate.rootLib.id, "helloString('world')")
            as InstanceRef;
        var world = await service.getObject(isolate.id, worldRef.id,
            count: 2, offset: 1) as Instance;
        expect(world.valueAsString, 'or');
        expect(world.count, 2);
        expect(world.length, 5);
        expect(world.offset, 1);
      });

      test('Strings with offset off the end', () async {
        var worldRef = await service.evaluate(
                isolate.id, isolate.rootLib.id, "helloString('world')")
            as InstanceRef;
        var world = await service.getObject(isolate.id, worldRef.id,
            count: 5, offset: 3) as Instance;
        expect(world.valueAsString, 'ld');
        expect(world.count, 2);
        expect(world.length, 5);
        expect(world.offset, 3);
      });

      test('Large strings with default truncation', () async {
        var largeString = await service.evaluate(isolate.id, isolate.rootLib.id,
            "helloString('${'abcde' * 250}')") as InstanceRef;
        expect(largeString.valueAsStringIsTruncated, true);
        expect(largeString.valueAsString.length, 128);
        expect(largeString.length, 5 * 250);
      });

      test('String at the truncation limit', () async {
        var largeString = await service.evaluate(
                isolate.id, isolate.rootLib.id, "helloString('${'a' * 128}')")
            as InstanceRef;
        expect(largeString.valueAsStringIsTruncated, false);
        expect(largeString.length, 128);
        expect(largeString.valueAsString.length, 128);
      });

      test('String one larger than the truncation limit', () async {
        var largeString = await service.evaluate(
                isolate.id, isolate.rootLib.id, "helloString('${'a' * 129}')")
            as InstanceRef;
        expect(largeString.valueAsStringIsTruncated, true);
        expect(largeString.length, 129);
        expect(largeString.valueAsString.length, 128);
      });

      /// Helper to create a list of 1001 elements, doing a direct JS eval.
      Future<RemoteObject> createList() {
        var expr = '''
          (function () {
            const sdk = ${globalLoadStrategy.loadModuleSnippet}("dart_sdk");
            const list = sdk.dart.dsend(sdk.core.List,"filled", [1001, 5]);
            list[4] = 100;
            return list;
      })()''';
        return service.appInspectorProvider().jsEvaluate(expr);
      }

      /// Helper to create a LinkedHashMap with 1001 entries, doing a direct JS eval.
      Future<RemoteObject> createMap() {
        var expr = '''
          (function () {
            const sdk = ${globalLoadStrategy.loadModuleSnippet}("dart_sdk");
            const iterable = sdk.dart.dsend(sdk.core.Iterable, "generate", [1001]);
            const list1 = sdk.dart.dsend(iterable, "toList", []);
            const reversed = sdk.dart.dload(list1, "reversed");
            const list2 = sdk.dart.dsend(reversed, "toList", []);
            const map = sdk.dart.dsend(list2, "asMap", []);
            const linkedMap = sdk.dart.dsend(sdk.collection.LinkedHashMap, "from", [map]);
            return linkedMap;
      })()''';
        return service.appInspectorProvider().jsEvaluate(expr);
      }

      test('Lists', () async {
        var list = await createList();
        var inst =
            await service.getObject(isolate.id, list.objectId) as Instance;
        expect(inst.length, 1001);
        expect(inst.offset, null);
        expect(inst.count, null);
        var fifth = inst.elements[4] as InstanceRef;
        expect(fifth.valueAsString, '100');
        var sixth = inst.elements[5] as InstanceRef;
        expect(sixth.valueAsString, '5');
      });

      test('Lists with count/offset', () async {
        var list = await createList();
        var inst = await service.getObject(isolate.id, list.objectId,
            count: 7, offset: 4) as Instance;
        expect(inst.length, 1001);
        expect(inst.offset, 4);
        expect(inst.count, 7);
        var fifth = inst.elements[0] as InstanceRef;
        expect(fifth.valueAsString, '100');
        var sixth = inst.elements[1] as InstanceRef;
        expect(sixth.valueAsString, '5');
      });

      test('Lists running off the end', () async {
        var list = await createList();
        var inst = await service.getObject(isolate.id, list.objectId,
            count: 5, offset: 1000) as Instance;
        expect(inst.length, 1001);
        expect(inst.offset, 1000);
        expect(inst.count, 1);
        var only = inst.elements[0] as InstanceRef;
        expect(only.valueAsString, '5');
      });

      test('Maps', () async {
        var map = await createMap();
        var inst =
            await service.getObject(isolate.id, map.objectId) as Instance;
        expect(inst.length, 1001);
        expect(inst.offset, null);
        expect(inst.count, null);
        var fifth = inst.associations[4];
        expect(fifth.key.valueAsString, '4');
        expect(fifth.value.valueAsString, '996');
        var sixth = inst.associations[5];
        expect(sixth.key.valueAsString, '5');
        expect(sixth.value.valueAsString, '995');
      });

      test('Maps with count/offset', () async {
        var map = await createMap();
        var inst = await service.getObject(isolate.id, map.objectId,
            count: 7, offset: 4) as Instance;
        expect(inst.length, 1001);
        expect(inst.offset, 4);
        expect(inst.count, 7);
        var fifth = inst.associations[0];
        expect(fifth.key.valueAsString, '4');
        expect(fifth.value.valueAsString, '996');
        var sixth = inst.associations[1];
        expect(sixth.key.valueAsString, '5');
        expect(sixth.value.valueAsString, '995');
      });

      test('Maps running off the end', () async {
        var map = await createMap();
        var inst = await service.getObject(isolate.id, map.objectId,
            count: 5, offset: 1000) as Instance;
        expect(inst.length, 1001);
        expect(inst.offset, 1000);
        expect(inst.count, 1);
        var only = inst.associations[0];
        expect(only.key.valueAsString, '1000');
        expect(only.value.valueAsString, '0');
      });

      test('bool', () async {
        var ref = await service.evaluate(
            isolate.id, isolate.rootLib.id, 'helloBool(true)') as InstanceRef;
        var obj = await service.getObject(isolate.id, ref.id) as Instance;
        expect(obj.kind, InstanceKind.kBool);
        expect(obj.classRef.name, 'Bool');
        expect(obj.valueAsString, 'true');
      });

      test('num', () async {
        var ref = await service.evaluate(
            isolate.id, isolate.rootLib.id, 'helloNum(42)') as InstanceRef;
        var obj = await service.getObject(isolate.id, ref.id) as Instance;
        expect(obj.kind, InstanceKind.kDouble);
        expect(obj.classRef.name, 'Double');
        expect(obj.valueAsString, '42');
      });

      test('null', () async {
        var ref = await service.evaluate(
            isolate.id, isolate.rootLib.id, 'helloNum(null)') as InstanceRef;
        var obj = await service.getObject(isolate.id, ref.id) as Instance;
        expect(obj.kind, InstanceKind.kNull);
        expect(obj.classRef.name, 'Null');
        expect(obj.valueAsString, 'null');
      });

      test('Scripts', () async {
        var scripts = await service.getScripts(isolate.id);
        assert(scripts.scripts.isNotEmpty);
        for (var scriptRef in scripts.scripts) {
          var script =
              await service.getObject(isolate.id, scriptRef.id) as Script;
          var serverPath = DartUri(script.uri, 'hello_world/').serverPath;
          var result =
              await http.get('http://localhost:${context.port}/$serverPath');
          expect(script.source, result.body);
          expect(scriptRef.uri, endsWith('.dart'));
          expect(script.tokenPosTable, isNotEmpty);
        }
      });
    });

    test('getScripts', () async {
      var vm = await service.getVM();
      var isolateId = vm.isolates.first.id;
      var scripts = await service.getScripts(isolateId);
      expect(scripts, isNotNull);
      expect(scripts.scripts, hasLength(greaterThan(0)));
      // Test for a known script
      expect(scripts.scripts.map((s) => s.uri),
          contains('package:path/path.dart'));
      // Should return part files as well.
      expect(
          scripts.scripts.map((s) => s.uri), contains(endsWith('part.dart')));
      expect(scripts.scripts.map((s) => s.uri),
          contains('package:intl/src/intl/date_format_helpers.dart'));
    });

    test('clearVMTimeline', () {
      expect(() => service.clearVMTimeline(), throwsUnimplementedError);
    });

    group('getSourceReport', () {
      test('Coverage report', () {
        expect(() => service.getSourceReport(null, ['Coverage']),
            throwsA(isA<ArgumentError>()));
      });

      test('report type not understood', () {
        // TODO(devoncarew): The VM returns:
        //   "error.code": -32602,
        //   "error.message": "Invalid params",
        //     "data.details": "getSourceReport: invalid 'reports' parameter: [FooBar]"
        expect(() => service.getSourceReport(null, ['FooBar']),
            throwsA(isA<ArgumentError>()));
      });

      test('PossibleBreakpoints report', () async {
        var vm = await service.getVM();
        var isolateId = vm.isolates.first.id;
        var scripts = await service.getScripts(isolateId);
        var mainScript = scripts.scripts
            .firstWhere((script) => script.uri.contains('main.dart'));

        final sourceReport = await service.getSourceReport(
          isolateId,
          ['PossibleBreakpoints'],
          scriptId: mainScript.id,
        );

        expect(sourceReport.scripts, isNotEmpty);
        expect(sourceReport.ranges, isNotEmpty);
        expect(sourceReport.ranges.first.possibleBreakpoints, isNotEmpty);
      });
    });

    group('Pausing', () {
      String isolateId;
      Stream<Event> stream;
      ScriptList scripts;
      ScriptRef mainScript;

      setUp(() async {
        var vm = await service.getVM();
        isolateId = vm.isolates.first.id;
        scripts = await service.getScripts(isolateId);
        await service.streamListen('Debug');
        stream = service.onEvent('Debug');
        mainScript = scripts.scripts
            .firstWhere((script) => script.uri.contains('main.dart'));
      });

      test('at breakpoints sets pauseBreakPoints', () async {
        var line = await context.findBreakpointLine(
            'callPrintCount', isolateId, mainScript);
        var bp = await service.addBreakpoint(isolateId, mainScript.id, line);
        var event = await stream
            .firstWhere((event) => event.kind == EventKind.kPauseBreakpoint);
        var pauseBreakpoints = event.pauseBreakpoints;
        expect(pauseBreakpoints, hasLength(1));
        expect(pauseBreakpoints.first.id, bp.id);
        await service.removeBreakpoint(isolateId, bp.id);
      });

      tearDown(() async {
        // Resume execution to not impact other tests.
        await service.resume(isolateId);
      });
    });

    group('Step', () {
      String isolateId;
      Stream<Event> stream;
      ScriptList scripts;
      ScriptRef mainScript;

      setUp(() async {
        var vm = await service.getVM();
        isolateId = vm.isolates.first.id;
        scripts = await service.getScripts(isolateId);
        await service.streamListen('Debug');
        stream = service.onEvent('Debug');
        mainScript = scripts.scripts
            .firstWhere((script) => script.uri.contains('main.dart'));
        var line = await context.findBreakpointLine(
            'callPrintCount', isolateId, mainScript);
        var bp = await service.addBreakpoint(isolateId, mainScript.id, line);
        // Wait for breakpoint to trigger.
        await stream
            .firstWhere((event) => event.kind == EventKind.kPauseBreakpoint);
        await service.removeBreakpoint(isolateId, bp.id);
      });

      tearDown(() async {
        // Resume execution to not impact other tests.
        await service.resume(isolateId);
      });

      test('Into goes to the next Dart location', () async {
        await service.resume(isolateId, step: 'Into');
        // Wait for the step to actually occur.
        await stream
            .firstWhere((event) => event.kind == EventKind.kPauseInterrupted);
        var stack = await service.getStack(isolateId);
        expect(stack, isNotNull);
        var first = stack.frames.first;
        expect(first.kind, 'Regular');
        expect(first.code.kind, 'Dart');
        expect(first.code.name, 'printCount');
      });

      test('Over goes to the next Dart location', () async {
        await service.resume(isolateId, step: 'Over');
        // Wait for the step to actually occur.
        await stream
            .firstWhere((event) => event.kind == EventKind.kPauseInterrupted);
        var stack = await service.getStack(isolateId);
        expect(stack, isNotNull);
        var first = stack.frames.first;
        expect(first.kind, 'Regular');
        expect(first.code.kind, 'Dart');
        expect(first.code.name, '<closure>');
      });

      test('Out goes to the next Dart location', () async {
        await service.resume(isolateId, step: 'Out');
        // Wait for the step to actually occur.
        await stream
            .firstWhere((event) => event.kind == EventKind.kPauseInterrupted);
        var stack = await service.getStack(isolateId);
        expect(stack, isNotNull);
        var first = stack.frames.first;
        expect(first.kind, 'Regular');
        expect(first.code.kind, 'Dart');
        expect(first.code.name, '<closure>');
      });
    });

    group('getStack', () {
      String isolateId;
      Stream<Event> stream;
      ScriptList scripts;
      ScriptRef mainScript;

      setUp(() async {
        var vm = await service.getVM();
        isolateId = vm.isolates.first.id;
        scripts = await service.getScripts(isolateId);
        await service.streamListen('Debug');
        stream = service.onEvent('Debug');
        mainScript = scripts.scripts
            .firstWhere((each) => each.uri.contains('main.dart'));
      });

      test('returns null if not paused', () async {
        expect(await service.getStack(isolateId), isNull);
      }, onPlatform: {'windows': const Skip('issues/721')});

      /// Support function for pausing and returning the stack at a line.
      Future<Stack> breakAt(String breakpointId) async {
        var lineNumber = await context.findBreakpointLine(
            breakpointId, isolateId, mainScript);
        var bp =
            await service.addBreakpoint(isolateId, mainScript.id, lineNumber);
        // Wait for breakpoint to trigger.
        await stream
            .firstWhere((event) => event.kind == EventKind.kPauseBreakpoint);
        // Remove breakpoint so it doesn't impact other tests.
        await service.removeBreakpoint(isolateId, bp.id);
        var stack = await service.getStack(isolateId);
        // Resume as to not impact other tests.
        await service.resume(isolateId);
        return stack;
      }

      test('returns stack when broken', () async {
        var stack = await breakAt('inPrintCount');
        expect(stack, isNotNull);
        expect(stack.frames, hasLength(2));
        var first = stack.frames.first;
        expect(first.kind, 'Regular');
        expect(first.code.kind, 'Dart');
        expect(first.code.name, 'printCount');
      });

      test('stack has a variable', () async {
        var stack = await breakAt('callPrintCount');
        expect(stack, isNotNull);
        expect(stack.frames, hasLength(1));
        var first = stack.frames.first;
        expect(first.kind, 'Regular');
        expect(first.code.kind, 'Dart');
        expect(first.code.name, '<closure>');
        // TODO: Make this more precise once this case doesn't
        // also include all the libraries.
        expect(first.vars, hasLength(greaterThanOrEqualTo(1)));
        var underscore = first.vars.firstWhere((v) => v.name == '_');
        expect(underscore, isNotNull);
      });

      test('returns non-empty stack when paused', () async {
        await service.pause(isolateId);
        // Wait for pausing to actually propagate.
        await stream
            .firstWhere((event) => event.kind == EventKind.kPauseInterrupted);
        expect(await service.getStack(isolateId), isNotNull);
        // Resume the isolate to not impact other tests.
        await service.resume(isolateId);
      });
    });

    test('getVM', () async {
      var vm = await service.getVM();
      expect(vm.name, isNotNull);
      expect(vm.version, Platform.version);
      expect(vm.isolates, hasLength(1));
      var isolate = vm.isolates.first;
      expect(isolate.id, isNotNull);
      expect(isolate.name, isNotNull);
      expect(isolate.number, isNotNull);
    });

    test('getVersion', () async {
      var version = await service.getVersion();
      expect(version, isNotNull);
      expect(version.major, greaterThan(0));
    });

    group('invoke', () {
      VM vm;
      Isolate isolate;
      InstanceRef testInstance;

      setUp(() async {
        vm = await service.getVM();
        isolate = await service.getIsolate(vm.isolates.first.id);
        testInstance = await service.evaluate(
            isolate.id, isolate.rootLib.id, 'myInstance') as InstanceRef;
      });

      test('toString()', () async {
        var remote =
            await service.invoke(isolate.id, testInstance.id, 'toString', []);
        expect(
            remote,
            const TypeMatcher<InstanceRef>().having(
                (instance) => instance.valueAsString,
                'toString()',
                "Instance of 'MyTestClass'"));
      });

      test('hello()', () async {
        var remote =
            await service.invoke(isolate.id, testInstance.id, 'hello', []);
        expect(
            remote,
            const TypeMatcher<InstanceRef>().having(
                (instance) => instance.valueAsString, 'hello()', 'world'));
      });

      test('helloString', () async {
        var remote = await service.invoke(isolate.id, isolate.rootLib.id,
            'helloString', ['#StringInstanceRef#abc']);
        expect(
            remote,
            const TypeMatcher<InstanceRef>().having(
                (instance) => instance.valueAsString, 'helloString', 'abc'));
        expect(
            remote,
            const TypeMatcher<InstanceRef>()
                .having((instance) => instance.kind, 'kind', 'String'));
      });

      test('null argument', () async {
        var remote = await service.invoke(
            isolate.id, isolate.rootLib.id, 'helloString', ['objects/null']);
        expect(
            remote,
            const TypeMatcher<InstanceRef>().having(
                (instance) => instance.valueAsString, 'helloString', 'null'));
        expect(
            remote,
            const TypeMatcher<InstanceRef>()
                .having((instance) => instance.kind, 'kind', 'Null'));
      });

      test('helloBool', () async {
        var remote = await service.invoke(
            isolate.id, isolate.rootLib.id, 'helloBool', ['objects/bool-true']);
        expect(
            remote,
            const TypeMatcher<InstanceRef>().having(
                (instance) => instance.valueAsString, 'helloBool', 'true'));
        expect(
            remote,
            const TypeMatcher<InstanceRef>()
                .having((instance) => instance.kind, 'kind', 'Bool'));
      });

      test('helloNum', () async {
        var remote = await service.invoke(
            isolate.id, isolate.rootLib.id, 'helloNum', ['objects/int-123']);
        expect(
            remote,
            const TypeMatcher<InstanceRef>().having(
                (instance) => instance.valueAsString, 'helloNum', '123'));
        expect(
            remote,
            const TypeMatcher<InstanceRef>()
                .having((instance) => instance.kind, 'kind', 'Double'));
      });

      test('two object arguments', () async {
        var remote = await service.invoke(isolate.id, isolate.rootLib.id,
            'messagesCombined', [testInstance.id, testInstance.id]);
        expect(
            remote,
            const TypeMatcher<InstanceRef>().having(
                (instance) => instance.valueAsString,
                'messagesCombined',
                'worldworld'));
        expect(
            remote,
            const TypeMatcher<InstanceRef>()
                .having((instance) => instance.kind, 'kind', 'String'));
      });
    });

    test('kill', () {
      expect(() => service.kill(null), throwsUnimplementedError);
    });

    test('onEvent', () {
      expect(() => service.onEvent(null), throwsUnimplementedError);
    });

    test('pause / resume', () async {
      await service.streamListen('Debug');
      var stream = service.onEvent('Debug');
      var vm = await service.getVM();
      var isolateId = vm.isolates.first.id;
      var pauseCompleter = Completer();
      var pauseSub = tabConnection.debugger.onPaused.listen((_) {
        pauseCompleter.complete();
      });
      var resumeCompleter = Completer();
      var resumeSub = tabConnection.debugger.onResumed.listen((_) {
        resumeCompleter.complete();
      });
      expect(await service.pause(isolateId), const TypeMatcher<Success>());
      await stream
          .firstWhere((event) => event.kind == EventKind.kPauseInterrupted);
      expect((await service.getIsolate(isolateId)).pauseEvent.kind,
          EventKind.kPauseInterrupted);
      await pauseCompleter.future;
      expect(await service.resume(isolateId), const TypeMatcher<Success>());
      await stream.firstWhere((event) => event.kind == EventKind.kResume);
      expect((await service.getIsolate(isolateId)).pauseEvent.kind,
          EventKind.kResume);
      await resumeCompleter.future;
      await pauseSub.cancel();
      await resumeSub.cancel();
    });

    test('getInboundReferences', () async {
      expect(() => service.getInboundReferences(null, null, null),
          throwsUnimplementedError);
    });

    test('getRetainingPath', () async {
      expect(() => service.getRetainingPath(null, null, null),
          throwsUnimplementedError);
    });

    test('registerService', () async {
      expect(() => service.registerService('ext.foo.bar', null),
          throwsUnimplementedError);
    });

    test('reloadSources', () {
      expect(() => service.reloadSources(null), throwsUnimplementedError);
    });

    test('setExceptionPauseMode', () async {
      var vm = await service.getVM();
      var isolateId = vm.isolates.first.id;
      expect(await service.setExceptionPauseMode(isolateId, 'all'), _isSuccess);
      expect(await service.setExceptionPauseMode(isolateId, 'unhandled'),
          _isSuccess);
      // Make sure this is the last one - or future tests might hang.
      expect(
          await service.setExceptionPauseMode(isolateId, 'none'), _isSuccess);
      expect(service.setExceptionPauseMode(isolateId, 'invalid'),
          throwsA(isA<ArgumentError>()));
    });

    test('setFlag', () {
      expect(() => service.setFlag(null, null), throwsUnimplementedError);
    });

    test('setLibraryDebuggable', () {
      expect(() => service.setLibraryDebuggable(null, null, null),
          throwsUnimplementedError);
    });

    test('setName', () async {
      var vm = await service.getVM();
      var isolateId = vm.isolates.first.id;
      expect(service.setName(isolateId, 'test'), completion(_isSuccess));
      var isolate = await service.getIsolate(isolateId);
      expect(isolate.name, 'test');
    });

    test('setVMName', () async {
      expect(service.setVMName('foo'), completion(_isSuccess));
      var vm = await service.getVM();
      expect(vm.name, 'foo');
    });

    test('setVMTimelineFlags', () {
      expect(() => service.setVMTimelineFlags(null), throwsUnimplementedError);
    });

    test('streamCancel', () {
      expect(() => service.streamCancel(null), throwsUnimplementedError);
    });

    group('streamListen/onEvent', () {
      group('Debug', () {
        Stream<Event> eventStream;

        setUp(() async {
          expect(await service.streamListen('Debug'),
              const TypeMatcher<Success>());
          eventStream = service.onEvent('Debug');
        });

        test('basic Pause/Resume', () async {
          expect(service.streamListen('Debug'), completion(_isSuccess));
          var stream = service.onEvent('Debug');
          unawaited(tabConnection.debugger.pause());
          await expectLater(
              stream,
              emitsThrough(const TypeMatcher<Event>()
                  .having((e) => e.kind, 'kind', EventKind.kPauseInterrupted)));
          unawaited(tabConnection.debugger.resume());
          expect(
              eventStream,
              emitsThrough(const TypeMatcher<Event>()
                  .having((e) => e.kind, 'kind', EventKind.kResume)));
        });

        test('Inspect', () async {
          expect(
              eventStream,
              emitsThrough(const TypeMatcher<Event>()
                  .having((e) => e.kind, 'kind', EventKind.kInspect)
                  .having(
                      (e) => e.inspectee,
                      'inspectee',
                      const TypeMatcher<InstanceRef>()
                          .having((instance) => instance.id, 'id', isNotNull)
                          .having((instance) => instance.kind, 'inspectee.kind',
                              InstanceKind.kPlainInstance))));
          await tabConnection.runtime.evaluate('inspectInstance()');
        });
      });

      test('Extension', () async {
        expect(service.streamListen('Extension'), completion(_isSuccess));
        var stream = service.onEvent('Extension');
        var eventKind = 'my.custom.event';
        expect(
            stream,
            emitsThrough(predicate((Event event) =>
                event.kind == EventKind.kExtension &&
                event.extensionKind == eventKind &&
                event.extensionData.data['example'] == 'data')));
        await tabConnection.runtime.evaluate("postEvent('$eventKind');");
      });

      test('GC', () async {
        expect(service.streamListen('GC'), completion(_isSuccess));
      });

      group('Isolate', () {
        Stream<Event> isolateEventStream;

        setUp(() async {
          expect(await service.streamListen('Isolate'), _isSuccess);
          isolateEventStream = service.onEvent('Isolate');
        });

        test('ServiceExtensionAdded', () async {
          var extensionMethod = 'ext.foo.bar';
          expect(
              isolateEventStream,
              emitsThrough(predicate((Event event) =>
                  event.kind == EventKind.kServiceExtensionAdded &&
                  event.extensionRPC == extensionMethod)));
          await tabConnection.runtime
              .evaluate("registerExtension('$extensionMethod');");
        });

        test('lifecycle events', () async {
          var vm = await service.getVM();
          var initialIsolateId = vm.isolates.first.id;
          var eventsDone = expectLater(
              isolateEventStream,
              emitsThrough(emitsInOrder([
                predicate((Event event) =>
                    event.kind == EventKind.kIsolateExit &&
                    event.isolate.id == initialIsolateId),
                predicate((Event event) =>
                    event.kind == EventKind.kIsolateStart &&
                    event.isolate.id != initialIsolateId),
                predicate((Event event) =>
                    event.kind == EventKind.kIsolateRunnable &&
                    event.isolate.id != initialIsolateId),
              ])));
          service.destroyIsolate();
          await service.createIsolate(context.appConnection);
          await eventsDone;
          expect((await service.getVM()).isolates.first.id,
              isNot(initialIsolateId));
        });
      });

      test('Timeline', () async {
        expect(service.streamListen('Timeline'), completion(_isSuccess));
      });

      test('Stdout', () async {
        expect(service.streamListen('Stdout'), completion(_isSuccess));
        expect(
            service.onEvent('Stdout'),
            emitsThrough(predicate((Event event) =>
                event.kind == EventKind.kWriteEvent &&
                String.fromCharCodes(base64.decode(event.bytes))
                    .contains('hello'))));
        await tabConnection.runtime.evaluate('console.log("hello");');
      });

      test('Stderr', () async {
        expect(service.streamListen('Stderr'), completion(_isSuccess));
        var stderrStream = service.onEvent('Stderr');
        expect(
            stderrStream,
            emitsThrough(predicate((Event event) =>
                event.kind == EventKind.kWriteEvent &&
                String.fromCharCodes(base64.decode(event.bytes))
                    .contains('Error'))));
        await tabConnection.runtime.evaluate('console.error("Error");');
      });

      test('VM', () async {
        var status = await service.streamListen('VM');
        expect(status, _isSuccess);
        var stream = service.onEvent('VM');
        expect(
            stream,
            emitsThrough(predicate((Event e) =>
                e.kind == EventKind.kVMUpdate && e.vm.name == 'test')));
        await service.setVMName('test');
      });
    });
  });

  group('shared context with fake evaluation', () {
    setUpAll(() async {
      await context.setUp(useFakeExpressionCompiler: true);
    });

    tearDownAll(() async {
      await context.tearDown();
    });

    group('evaluateInFrame', () {
      VM vm;
      Isolate isolate;
      ScriptList scripts;
      ScriptRef mainScript;
      Stream<Event> stream;

      setUp(() async {
        vm = await service.getVM();
        isolate = await service.getIsolate(vm.isolates.first.id);
        scripts = await service.getScripts(isolate.id);

        await service.streamListen('Debug');
        stream = service.onEvent('Debug');

        mainScript = scripts.scripts
            .firstWhere((each) => each.uri.contains('main.dart'));
      });

      tearDown(() async {
        await service.resume(isolate.id);
      });

      test('local', () async {
        expect(service.streamListen('Stdout'), completion(_isSuccess));
        var output = service.onEvent('Stdout');

        expect(
            output,
            emitsThrough(predicate((Event event) =>
                event.kind == EventKind.kWriteEvent &&
                String.fromCharCodes(base64.decode(event.bytes))
                    .contains('42'))));

        var line = await context.findBreakpointLine(
            'printLocal', isolate.id, mainScript);
        var bp = await service.addBreakpointWithScriptUri(
            isolate.id, mainScript.uri, line);

        var event = await stream.firstWhere(
            (Event event) => event.kind == EventKind.kPauseBreakpoint);

        var result = await service.evaluateInFrame(
            isolate.id, event.topFrame.index, 'local');

        expect(
            result,
            const TypeMatcher<InstanceRef>().having(
                (instance) => instance.valueAsString, 'valueAsString', '42'));

        // Remove breakpoint so it doesn't impact other tests.
        await service.removeBreakpoint(isolate.id, bp.id);
      });

      test('call core function', () async {
        expect(service.streamListen('Stdout'), completion(_isSuccess));
        var output = service.onEvent('Stdout');

        expect(
            output,
            emitsThrough(predicate((Event event) =>
                event.kind == EventKind.kWriteEvent &&
                String.fromCharCodes(base64.decode(event.bytes))
                    .contains('null'))));

        var line = await context.findBreakpointLine(
            'printLocal', isolate.id, mainScript);
        var bp = await service.addBreakpointWithScriptUri(
            isolate.id, mainScript.uri, line);

        var event = await stream.firstWhere(
            (Event event) => event.kind == EventKind.kPauseBreakpoint);

        var result = await service.evaluateInFrame(
            isolate.id, event.topFrame.index, 'core.print(local)');

        expect(
            result,
            const TypeMatcher<InstanceRef>().having(
                (instance) => instance.valueAsString, 'valueAsString', 'null'));

        // Remove breakpoint so it doesn't impact other tests.
        await service.removeBreakpoint(isolate.id, bp.id);
      });

      test('error', () async {
        expect(service.streamListen('Stderr'), completion(_isSuccess));
        var output = service.onEvent('Stderr');

        expect(
            output,
            emitsThrough(predicate((Event event) =>
                event.kind == EventKind.kWriteEvent &&
                String.fromCharCodes(base64.decode(event.bytes))
                    .contains('ReferenceError: typo is not defined'))));

        var line = await context.findBreakpointLine(
            'printLocal', isolate.id, mainScript);
        var bp = await service.addBreakpointWithScriptUri(
            isolate.id, mainScript.uri, line);

        var event = await stream.firstWhere(
            (Event event) => event.kind == EventKind.kPauseBreakpoint);

        var error = await service.evaluateInFrame(
            isolate.id, event.topFrame.index, 'typo');

        expect(
            error,
            const TypeMatcher<ErrorRef>().having((instance) => instance.message,
                'message', 'ReferenceError: typo is not defined'));

        // Remove breakpoint so it doesn't impact other tests.
        await service.removeBreakpoint(isolate.id, bp.id);
      });
    });
  });
}

final _isSuccess = isA<Success>();

TypeMatcher _libRef(uriMatcher) =>
    isA<LibraryRef>().having((l) => l.uri, 'uri', uriMatcher);
