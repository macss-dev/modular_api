// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';

import 'package:modular_api/src/clients/db/odbc/libodbc.dart';

///
class LibOdbcExt extends LibOdbc {
  ///
  LibOdbcExt(super.dynamicLibrary);

  @override
  int SQLAllocHandle(
    int HandleType,
    SQLHANDLE InputHandle,
    Pointer<SQLHANDLE> OutputHandle,
  ) {
    try {
      return super.SQLAllocHandle(HandleType, InputHandle, OutputHandle);
    } catch (e) {
      if (HandleType == SQL_HANDLE_DBC) {
        return super.SQLAllocConnect(InputHandle, OutputHandle);
      } else if (HandleType == SQL_HANDLE_ENV) {
        return super.SQLAllocEnv(OutputHandle);
      } else if (HandleType == SQL_HANDLE_STMT) {
        return super.SQLAllocStmt(InputHandle, OutputHandle);
      } else {
        rethrow;
      }
    }
  }
}
