import 'package:drift/drift.dart';

import 'unsupported.dart'
    if (dart.library.ffi) 'native.dart'
    if (dart.library.js_interop) 'web.dart';

QueryExecutor openConnection() => openConnectionImpl();
