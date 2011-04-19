/**
 * Appcelerator Titanium Mobile
 * Copyright (c) 2009-2011 by Appcelerator, Inc. All Rights Reserved.
 * Licensed under the terms of the Apache Public License
 * Please see the LICENSE included with this distribution for details.
 */

#import <Foundation/Foundation.h>
#import "TiProxy.h"
#import "TiBlob.h"

// TODO: Support array-style access of bytes
@interface TiBuffer : TiProxy {
    NSMutableData* data;
    
}
@property(nonatomic, retain) NSMutableData* data;
 
// Public API
-(NSNumber*)append:(id)args;
-(NSNumber*)insert:(id)args;
-(NSNumber*)copy:(id)args;
-(TiBuffer*)clone:(id)args;
-(void)fill:(id)args;

-(NSNumber*)clear:(id)_void;
-(NSNumber*)release:(id)_void;

-(TiBlob*)toBlob:(id)_void;
-(NSString*)toString:(id)_void;

@property(nonatomic,assign) NSNumber* length;

// SPECIAL NOTES:
// Ti.Buffer objects have an 'overloaded' Ti.Buffer[x] operation for x==int (making them behave like arrays).
// See the code for how this works.

@end
