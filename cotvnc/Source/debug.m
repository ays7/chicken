/*
 *  debug.m
 *  Chicken of the VNC
 *
 *  Created by Kurt Werle on Thu Dec 19 2002.
 *  Copyright (c) 2001 __MyCompanyName__. All rights reserved.
 *
 */

#import "debug.h"
#import <Foundation/Foundation.h>

DiagnosticLogLevel GetDiagnosticLogLevel(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"DiagnosticLoggingLevel"] != nil) {
        return (DiagnosticLogLevel)[defaults integerForKey:@"DiagnosticLoggingLevel"];
    }
    if ([defaults boolForKey:@"EnableDiagnosticLogging"]) {
        return DiagnosticLogLevelBasic;
    }
    return DiagnosticLogLevelNone;
}

BOOL IsDiagnosticLoggingEnabled(DiagnosticLogLevel level) {
    return GetDiagnosticLogLevel() >= level;
}

void DiagnosticLog(DiagnosticLogLevel level, NSString *format, ...) {
    if (!IsDiagnosticLoggingEnabled(level)) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[Chicken] %@", msg);
    [msg release];
}

void DoNothing(NSString *format, ...) {

}

