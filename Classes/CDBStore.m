/*
 CDBStore.m
 Created by Jens Alfke on 2/4/08.

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

#import "CDBStore.h"


#ifndef LogTo
#define kEnableLog 0    /* 1 enables logging, 0 disables it */
#define LogTo(DOMAIN,MSG,...) do{ if(kEnableLog) NSLog(@""#DOMAIN#": "#MSG,__VA_ARGS__); }while(0)
#endif

#ifndef Warn
#define Warn(MSG,...) NSLog(@"WARNING: " #MSG,__VA_ARGS__)
#endif


@interface CDBStoreEnumerator : NSEnumerator
{
    CDBStore *_store;
    CDBEnumerator *_fileEnumerator;
    NSMutableSet *_changedEncodedKeys;
    NSEnumerator *_addedKeyEnumerator;
    BOOL _returnKeys;
}
- (id) initWithStore: (CDBStore*)store 
              reader: (CDBReader*)reader
         changedKeys: (NSSet*)changedEncodedKeys
          returnKeys: (BOOL)returnKeys;
@end



@implementation CDBStore


static id kDeletedValueMarker;

+ (void) initialize
{
    // Create a guaranteed-unique object to use as a placeholder value in _cache
    // that represents a nil value (a deleted object.)
    if( ! kDeletedValueMarker )
        kDeletedValueMarker = [[NSObject alloc] init];
}


- (id) initWithFile: (NSString*)name
{
    NSParameterAssert(name!=nil);
    self = [super init];
    if (self != nil) {
        _path = [name copy];
        _cache = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void) dealloc
{
    [_cache release];
    [_changedEncodedKeys release];
    [_path release];
    [_reader release];
    [super dealloc];
}


@synthesize file=_path;


- (BOOL) open: (NSError**)outError
{
    if( !_isOpen ) {
        if( _path ) {
            _reader = [[CDBReader alloc] initWithFile: _path];
            if( ! [_reader open] ) {
                if( _reader.error.code == ENOENT ) {
                    // OK to open file that doesn't exist yet
                    [_reader clearError];
                } else {
                    *outError = _reader.error;
                    return NO;
                }
            }
        }
        _isOpen = YES;
    }
    return YES;
}

- (BOOL) isOpen
{
    return _isOpen;
}

- (BOOL) exists
{
    if( _isOpen )
        return _reader.isOpen;
    else
        return [[NSFileManager defaultManager] fileExistsAtPath: _path];
}


- (void) emptyCache
{
    NSMutableDictionary *newCache = [[NSMutableDictionary alloc] init];
    for( NSData* encodedKey in _changedEncodedKeys ) {
        id key = [self decodeKey: CDBFromNSData(encodedKey)];
        [newCache setObject: [_cache objectForKey: key] forKey: key];
    }
    [_cache release];
    _cache = newCache;
}


- (BOOL) close
{
    BOOL ok = !_isOpen || [self save: nil];     // Save any pending changes
    [_reader close];
    [_reader release];
    _reader = nil;
    _isOpen = NO;
    [_cache removeAllObjects];
    [_changedEncodedKeys release];
    _changedEncodedKeys = nil;
    return ok;
}


#pragma mark -
#pragma mark READING:


- (id) objectForKey: (id)key dataPointer: (CDBData)data
{
    NSAssert(_isOpen,@"CDBStore is not open");
    // Check cache first:
    id object = [_cache objectForKey: key];
    if( object ) {
        if( object == kDeletedValueMarker )
            object = nil;
        return object;
    }
    
    // Look up key in file, if file exists:
    if( ! _reader.isOpen )
        return nil;
    if( ! data.bytes ) {
        data = [_reader valuePointerForKey: [self encodeKey: key]];
        if( ! data.bytes )
            return nil;
    }
    
    // Decode and cache the object:
    NSAssert(data.length>0,@"Bogus value");
    const UInt8* tagPtr = data.bytes;
    data.bytes = tagPtr+1;
    data.length--;
    object = [self decodeObject: data tag: *tagPtr];
    NSAssert1(object,@"CDBStore failed to decode object for key %@",key);
    [_cache setObject: object forKey: key];
    LogTo(CDB,@"objectForKey: %@ is %@<%p>",key,[object class],object);
    return object;
}


- (id) objectForKey: (id)key
{
    return [self objectForKey: key dataPointer: (CDBData){NULL,0}];
}


- (NSEnumerator*) keyEnumerator
{
    return [[[CDBStoreEnumerator alloc] initWithStore: self
                                               reader: _reader
                                          changedKeys: _changedEncodedKeys
                                           returnKeys: YES]
                autorelease];
}


- (NSEnumerator*) objectEnumerator
{
    return [[[CDBStoreEnumerator alloc] initWithStore: self
                                               reader: _reader
                                          changedKeys: _changedEncodedKeys
                                           returnKeys: NO]
            autorelease];
}


- (NSDictionary*) allKeysAndValues
{
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    for( id key in self.keyEnumerator )
        [dict setObject: [self objectForKey: key] forKey: key];
    return dict;
}


#pragma mark -
#pragma mark WRITING:


- (void) _willChange
{
    NSAssert(_isOpen,@"CDBStore is not open");
    if( ! _changedEncodedKeys )
        _changedEncodedKeys = [[NSMutableSet alloc] init];
    if( _autosaveInterval > 0 )
        [self saveSoon];
}


- (void) setObject: (id)object forKey: (id)key
{
    if( ! object )
        object = kDeletedValueMarker;
    if( ! [object isEqual: [_cache objectForKey: key]] ) {
        // Make sure the key is encodable, before adding it:
        NSData *encodedKey = CDBToNSData([self encodeKey: key]);
        NSAssert2(encodedKey, @"Key %@<%p> is not encodable",[key class],key);
        [self _willChange];
        LogTo(CDB,@"setObject: %@<%p> forKey: %@",[object class],object,key);
        [_cache setObject: object forKey: key];
        [_changedEncodedKeys addObject: encodedKey];
    }
}


- (void) _addToChangedKeys: (id)key
{
    NSData *encodedKey = CDBToNSData([self encodeKey: key]);
    NSAssert2(encodedKey, @"Key %@<%p> is not encodable",[key class],key);
    [_changedEncodedKeys addObject: encodedKey];
}


- (void) objectChangedForKey: (id)key
{
    id object = [_cache objectForKey: key];
    if( ! object ) {
        Warn(@"CDBStore objectChangedForKey: --no object for key %@",key);
        return;
    }
    [self _willChange];
    [self _addToChangedKeys: key];
    LogTo(CDB,@"objectChangedForKey: %@",key);
}


- (void) objectChanged: (id)object
{
    NSArray *keys = [_cache allKeysForObject: object];      // Inefficient if cache is large (linear search)
    if( keys ) {
        [self _willChange];
        for( id key in keys )
            [self _addToChangedKeys: key];
    }
    LogTo(CDB,@"objectChanged: %@<%p> ... keys= %@",[object class],object,keys);
}


- (BOOL) isDeletedKey: (id)key
{
    return [_cache objectForKey: key] == kDeletedValueMarker;
}


#pragma mark -
#pragma mark SAVING:


- (BOOL) hasChanges
{
    return _changedEncodedKeys != nil;
}

- (NSSet*) changedKeys
{
    if( ! _changedEncodedKeys )
        return nil;
    NSMutableSet *keys = [NSMutableSet setWithCapacity: _changedEncodedKeys.count];
    for( NSData *encodedKey in _changedEncodedKeys )
        [keys addObject: [self decodeKey: CDBFromNSData(encodedKey)]];
    return keys;
}


@synthesize autosaveInterval=_autosaveInterval;


- (BOOL) _writeEncodedKey: (NSData*)encodedKey toFile: (CDBWriter*)writer
{
    BOOL ok = YES;
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    @try{
        CDBData keyBytes = CDBFromNSData(encodedKey);
        id key = [self decodeKey: keyBytes];
        id object = [_cache objectForKey: key];
        if( object && object != kDeletedValueMarker ) {
            UInt8 tag;
            NSData *objectData = [self encodeObject: object tag: &tag];
            NSAssert1(objectData,@"CDBStore failed to encode object for key %@",key);
            CDBData values[2] = { {&tag,1}, CDBFromNSData(objectData) };
            ok = [writer addValuePointers: values count: 2 forKey: keyBytes];
        }
    }@finally{
        [pool drain];
    }
    return ok;
}


- (BOOL) save: (NSError**)outError
{
    _savingSoon = NO;
    if( ! _changedEncodedKeys || ! _isOpen )
        return YES;
    
    LogTo(CDB,@"Saving %@",self.file);
    NSError *tempError;
    if( ! outError )
        outError = &tempError;

    // Open temporary file to write to:
    BOOL ok = YES;
    NSString *tempPath = [self.file stringByAppendingString: @"~temp"];
    //TODO: Choose a unique filename instead, in a hidden temporary directory on the same filesystem.
    CDBWriter *writer = [[CDBWriter alloc] initWithFile: tempPath];
    if( ! [writer open] ) {
        *outError = writer.error;
        [writer release];
        return NO;
    }
    
    @try{
        if( _reader.isOpen ) {
            // Write existing values from file, whether or not they were cached or changed:
            CDBEnumerator *e = [_reader keyEnumerator];
            NSMutableData *encodedKeyData = [NSMutableData data];
            while( [e next] ) {
                CDBData keyBytes = e.keyPointer;
                [encodedKeyData replaceBytesInRange: NSMakeRange(0,encodedKeyData.length)
                                          withBytes: keyBytes.bytes 
                                             length: keyBytes.length];
                if( [_changedEncodedKeys containsObject: encodedKeyData] ) {
                    // Externalize changed object:
                    ok = [self _writeEncodedKey: encodedKeyData toFile: writer];
                    [_changedEncodedKeys removeObject: encodedKeyData];
                } else {
                    // Just pass unmodified value through directly from old file:
                    ok = [writer addValuePointer: e.valuePointer forKey: keyBytes];
                }
                if( ! ok ) break;
            }
        }
        
        // Write objects for newly-added keys:
        for( NSData *newKey in _changedEncodedKeys ) {
            ok = [self _writeEncodedKey: newKey toFile: writer];
            if( ! ok )
                break;
        }
        
        ok = [writer close] && ok;
    }@catch( NSException *x ) {
        Warn(@"CDBStore save failed: %@",x);
        [writer close];
        ok = NO;
    }

    *outError = writer.error;
    [writer release];
    
    // Replace old file with new:
    if( ok && rename(tempPath.fileSystemRepresentation, self.file.fileSystemRepresentation) != 0 ) {
        // Oops, failed to replace
        ok = NO;
        *outError = [NSError errorWithDomain: NSPOSIXErrorDomain code: errno userInfo: nil];
    }
    
    if( ok ) {
        // Re-open, and clear internal change state:
        [_reader close];
        [_changedEncodedKeys release];
        _changedEncodedKeys = nil;
        ok =_isOpen = [_reader open];
        if( ! ok )
            *outError = _reader.error;
    } else {
        // Failed -- at least clean up the temp file
        [[NSFileManager defaultManager] removeItemAtPath: tempPath error: nil];
    }
    
    if( ! ok )
        Warn(@"CDBStore: Save failed: %@",*outError);
    return ok;
    // Done!
}


- (void) saveSoon
{
    if( ! _savingSoon ) {
        [self performSelector: @selector(save:) withObject: nil afterDelay: _autosaveInterval];
        _savingSoon = YES;
    }
}


#pragma mark -
#pragma mark ENCODING/DECODING HOOKS:


- (CDBData) encodeKey: (id)key
{
    return CDBFromNSData(key);
}


- (id) decodeKey: (CDBData)keyData
{
    return CDBToNSData(keyData);
}


- (NSData*) encodeObject: (id)object tag: (UInt8*)outTag
{
    if( [object isKindOfClass: [NSData class]] ) {
        *outTag = 0;
        return object;
    } else if( [object isKindOfClass: [NSString class]] ) {
        *outTag = 1;
        return [object dataUsingEncoding: NSUTF8StringEncoding];
#if 0
    } else if( [object isKindOfClass: [NSValue class]] ) {
        *outTag = 2;
        //TODO: Finish implementing optimized encode support for NSValues.
#endif
    } else {
        // As a fallback, any object supporting NSCoding can be encoded:
        *outTag = 3;
        return [NSKeyedArchiver archivedDataWithRootObject: object];
    }
}


- (id) decodeObject: (CDBData)data tag: (UInt8)tag
{
    switch( tag ) {
        case 0: // NSData:
            return [[NSData alloc] initWithBytes: data.bytes
                                          length: data.length];
        case 1: // NSString:
            return [[NSString alloc] initWithBytes: data.bytes length: data.length
                                          encoding: NSUTF8StringEncoding];
        case 2: { // NSValue:
            const char *type = (const char*) data.bytes;
            return [NSValue valueWithBytes: type+strlen(type)+1 objCType: type];
        }
        case 3: { // NSKeyedArchive:
            NSData *dataObj = [[NSData alloc] initWithBytesNoCopy: (void*)data.bytes
                                                           length: data.length
                                                     freeWhenDone: NO];
            id object = [NSKeyedUnarchiver unarchiveObjectWithData: dataObj];
            [dataObj release];
            return object;
        }
        default:
            Warn(@"CDBStore: decodeObject got unknown tag %u",(unsigned)tag);
            return nil;
    }
}


@end




@implementation CDBStringKeyStore

// Uses NSString objects as keys.
- (CDBData) encodeKey: (id)key
{
    return CDBFromNSData([key dataUsingEncoding: NSUTF8StringEncoding]);
}

- (id) decodeKey: (CDBData)encodedKey
{
    return [[[NSString alloc] initWithBytes: encodedKey.bytes length: encodedKey.length
                                   encoding: NSUTF8StringEncoding]
            autorelease];
}

@end




@implementation CDBStoreEnumerator

- (id) initWithStore: (CDBStore*)store 
              reader: (CDBReader*)reader
         changedKeys: (NSSet*)changedEncodedKeys
          returnKeys: (BOOL)returnKeys;
{
    self = [super init];
    if( self ) {
        _store = store;
        if( reader.isOpen )
            _fileEnumerator = [reader.keyEnumerator retain];
        _changedEncodedKeys = [changedEncodedKeys mutableCopy];
        _returnKeys = returnKeys;
    }
    return self;
}

- (void) dealloc
{
    [_fileEnumerator release];
    [_changedEncodedKeys release];
    [_addedKeyEnumerator release];
    [super dealloc];
}


- (id) nextObject
{
    // Enumerate through the keys in the existing file:
    while( [_fileEnumerator next] ) {
        CDBData keyBytes = _fileEnumerator.keyPointer;
        id key = [_store decodeKey: keyBytes];
        [_changedEncodedKeys removeObject: CDBToNSData(keyBytes)];
        // Return current key or value, if it hasn't been deleted:
        if( _returnKeys ) {
            if( ! [_store isDeletedKey: key] )
                return key;
        } else {
            id value = [_store objectForKey: key dataPointer: _fileEnumerator.valuePointer];
            if( value )
                return value;             // found a non-deleted object to return
        }
    }
    
    // If we've finished iterating the file, go through the remaining added keys:
    if( _changedEncodedKeys ) {
        _addedKeyEnumerator = [[_changedEncodedKeys objectEnumerator] retain];
        [_changedEncodedKeys release];
        _changedEncodedKeys = nil;
    }
    
    id encodedKey = [_addedKeyEnumerator nextObject];
    if( encodedKey==nil )
        return nil;
    else {
        id key = [_store decodeKey: CDBFromNSData(encodedKey)];
        if( _returnKeys )
            return key;
        else 
            return [_store objectForKey: key];
    }
}

@end
