/*
 CDBFileTest.m
 Created by Jens Alfke on 2/7/08.

 Copyright (c) 2008, Jens Alfke. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification, are permitted
 provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright notice, this list of conditions
 and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions
 and the following disclaimer in the documentation and/or other materials provided with the
 distribution.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND 
 FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRI-
 BUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR 
  PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN 
 CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF 
 THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "CDBFile.h"
#import "CDBStore.h"


//TODO: These tests are still pretty superficial and don't exercise enough of the API. (2/08)


static void CDBFileTest(void)
{
    NSLog(@"--- Starting CDBFileTest ---");
    NSString * const kDir = @"/Applications/TextEdit.app";
    NSString * const kTempFile = @"/tmp/TextEdit.cdb";
    
    NSLog(@"Writing a CDB file...");
    CDBWriter *writer = [[CDBWriter alloc] initWithFile: kTempFile];
    NSCAssert1( [writer open], @"Failed to open writer: %@", writer.error );
    NSError *error;
    int n = 0;
    for( NSString *name in [[NSFileManager defaultManager] subpathsOfDirectoryAtPath: kDir
                                                                               error: &error] ) {
        NSAutoreleasePool *pool = [NSAutoreleasePool new];
        NSString *path = [kDir stringByAppendingPathComponent: name];
        BOOL isDir;
        if( [[NSFileManager defaultManager] fileExistsAtPath: path isDirectory: &isDir] && ! isDir ) {
            //NSLog(@"Adding %@",name);
            NSData *contents = [[NSData alloc] initWithContentsOfFile: path
                                                              options: NSUncachedRead
                                                                error: &error];
            NSCAssert2(contents,@"Couldn't read %@: %@",path,error);
            [writer addValuePointer: CDBFromNSData(contents) 
                             forKey: CDBFromNSString(name)];
            [contents release];
            n++;
        }
        [pool drain];
    }
    NSLog(@"Added %i items. Saving...",n);
    NSCAssert1([writer close], @"close failed: %@",writer.error);
    [writer release];

    NSLog(@"Reading & verifying the CDB...");
    CDBReader *reader = [[CDBReader alloc] initWithFile: kTempFile];
    NSCAssert1( [reader open], @"Failed to open reader: %@", reader.error );
    for( NSString *name in [[NSFileManager defaultManager] subpathsOfDirectoryAtPath: kDir
                                                                               error: &error] ) {
        NSAutoreleasePool *pool = [NSAutoreleasePool new];
        NSString *path = [kDir stringByAppendingPathComponent: name];
        BOOL isDir;
        if( [[NSFileManager defaultManager] fileExistsAtPath: path isDirectory: &isDir] && ! isDir ) {
            NSData *contents = [[NSData alloc] initWithContentsOfFile: path
                                                              options: NSUncachedRead
                                                                error: &error];
            NSCAssert2(contents,@"Couldn't read %@: %@",path,error);
            //NSLog(@"Checking %@ (%u bytes)",name,contents.length);
            
            CDBData readContents = [reader valuePointerForKey: CDBFromNSString(name)];
            NSCAssert2( readContents.length == contents.length, @"Expected %u bytes but read %u",
                      contents.length,readContents.length);
            NSCAssert( memcmp(readContents.bytes,contents.bytes,readContents.length)==0, @"Contents differ");
            [contents release];
        }
        [pool drain];
    }
    NSCAssert1([reader close], @"close failed: %@",reader.error);
    [reader release];
    NSLog(@"+++ CDBFileTest passed +++");
}


static void CDBStoreTest(void)
{
    NSLog(@"--- Starting CDBStoreTest ---");
    NSError *error;
    NSString *dir;
    NSLog(@"Creating store...");
    CDBStore *store = [[CDBStore alloc] initWithFile: @"/tmp/test.cdb"];
    NSCAssert1( [store open: &error], @"Couldn't open store: %@",error );
    
    NSLog(@"Adding values to store...");
    dir = @"/usr/lib";
    for( NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath: dir
                                                                               error: &error] ) {
        //Log(@"Adding %@",name);
        NSString *path = [dir stringByAppendingPathComponent: name];
        NSDictionary *attrs = [[NSFileManager defaultManager] fileAttributesAtPath: path traverseLink: NO];
        [store setObject: attrs forKey: [name dataUsingEncoding: NSUTF8StringEncoding]];
    }
    NSLog(@"Saving...");
    NSCAssert1([store save: &error], @"save failed: %@",error);
    [store close];
    [store release];
    
    NSLog(@"Re-opening and verifying store...");
    store = [[CDBStore alloc] initWithFile: @"/tmp/test.cdb"];
    NSCAssert1( [store open: &error], @"Couldn't open store: %@",error );
    for( NSData *key in store.keyEnumerator ) {
        NSString *keyStr = [[NSString alloc] initWithData: key encoding: NSUTF8StringEncoding];
        id value = [store objectForKey: key];
        NSCAssert1(value,@"Failed to read a value for %@",key);
        NSCAssert1([value isKindOfClass: [NSDictionary class]],@"Unexpected class %@ for value",[value class]);
        //Log(@"%@ = %@", keyStr,value);
        [keyStr release];
    }
    [store close];
    [store release];
    NSLog(@"+++ CDBStoreTest passed +++");
}


static void CDBStoreUpdateTest(void)
{
    NSLog(@"--- Starting CDBStoreUpdateTest ---");
    NSError *error;
    CDBStore *store = nil;
    unlink("/tmp/test_updates.cdb");
    
    NSMutableDictionary *shadow = [NSMutableDictionary dictionary];
    
    int pass,i;
    for( pass=0; pass<16; pass++ ) {
        if( ! store ) {
            NSLog(@"Opening store");
            store = [[StringKeyCDBStore alloc] initWithFile: @"/tmp/test_updates.cdb"];
            NSCAssert1( [store open: &error], @"Couldn't open store: %@",error );
            NSLog(@"Verifying store contents");
            NSCAssert2( [store.allKeysAndValues isEqual: shadow], @"Contents don't match:\nstore = %@\nshadow = %@",
                       store.allKeysAndValues,shadow);
            [store emptyCache];
        }            
        NSLog(@"Starting pass #%i",pass);
        for( i=0; i < 100; i++ ) {
            NSString *key = [NSString stringWithFormat: @"%u", random()%400];
            NSString *value = [NSString stringWithFormat: @"I am the value of key %@ on pass #%i, with random number %u",
                     key,pass,random()];
            [shadow setObject: value forKey: key];
            [store setObject: value forKey: key];
            NSCAssert([[store objectForKey: key] isEqual: [shadow objectForKey: key]], @"Unexpected value");
        }
        NSCAssert1([store save: &error],@"Save failed: %@",error);
        if( pass%4 == 3 ) {
            NSLog(@"Verifying store contents");
            NSCAssert2( [store.allKeysAndValues isEqual: shadow], @"Contents don't match:\nstore = %@\nshadow = %@",
                                                                store.allKeysAndValues,shadow);
            NSLog(@"Closing store");
            [store close];
            [store release];
            store = nil;
        }
    }
    NSLog(@"--- CDBStoreUpdateTest Passed ---");
}


int main( int argc, const char **argv )
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    CDBFileTest();
    CDBStoreTest();
    CDBStoreUpdateTest();
    [pool drain];
    return 0;
}