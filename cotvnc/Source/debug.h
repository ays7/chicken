/*
 *  debug.h
 *  Chicken of the VNC
 *
 *  Created by Kurt Werle on Thu Dec 19 2002.
 *  Copyright (c) 2001 __MyCompanyName__. All rights reserved.
 *
 */

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DiagnosticLogLevel) {
    DiagnosticLogLevelNone = 0,
    DiagnosticLogLevelBasic = 1,
    DiagnosticLogLevelVerbose = 2
};

DiagnosticLogLevel GetDiagnosticLogLevel(void);
BOOL IsDiagnosticLoggingEnabled(DiagnosticLogLevel level);
void DiagnosticLog(DiagnosticLogLevel level, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

void DoNothing(NSString *format, ...);
