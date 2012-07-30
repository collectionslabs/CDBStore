/*
 CDBFile.h
 Created by Jens Alfke on 2/3/08.

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

#import <Foundation/Foundation.h>
#import "cdb.h"
@class CDBEnumerator;

/** @file */
// @{

/** CDBData is a simple struct for pointing to a block of memory. */
typedef struct {
    const void *bytes;      //!< Pointer to the start of the memory block
    size_t length;          //!< Length of the memory block
} CDBData;

/** Returns a CDBData pointing to the contents of an NSData. */
CDBData CDBFromNSData( NSData* );
/** Returns a CDBData pointing to the UTF-8 contents of an NSString. */
CDBData CDBFromNSString( NSString* );       
/** Returns a CDBData pointing to the bytes of a C string (without the trailing null byte). */
CDBData CDBFromCString( const char* );

/** Creates an NSData object containing a copy of the bytes pointed to by a CDBData. */
NSData* CDBToNSData( CDBData );             
/** Creates an NSData object that points directly to the same bytes as a CDBData, without copying them. */
NSData* CDBToNSDataNoCopy( CDBData );
/** Creates an NSString from the UTF-8 string pointed to by a CDBData. */
NSString* CDBToNSString( CDBData );

// }@


/** Abstract base class for CDB files. */

@interface CDBFile : NSObject
{
    @private
    NSString *_path;
    int _fd;
    int _error;
}

/** Opens the file.
    @return  YES on success, no on failure; in the latter case, check, the error property. */
- (BOOL) open;

/** Closes the file.
    @return  YES on success, no on failure; in the latter case, check, the error property. */
- (BOOL) close;

/** Deletes the file.
    Don't call this while the file is open. */
- (BOOL) deleteFile;

/** The path of the file, as given to the -initWithFile: method. */
@property (readonly) NSString *file;

/** The underlying file descriptor, while the file is open. */
@property (readonly) int fileDescriptor;

/** Is the file open? */
@property (readonly) BOOL isOpen;

/** Any error will be stored in this property.
    It won't be cleared back to nil until -clearError or -close is called. */
@property (readonly) NSError* error;

/** Clears the error property back to nil, without closing the file. */
- (void) clearError;

@end



/** Read-only access to CDB files.
    This is a thin Objective-C wrapper around Michael Tokarev's 
    <a href="http://www.corpit.ru/mjt/tinycdb.html">tinycdb</a> library,
    which is itself a rewrite of Dan Bernstein's <a href="http://cr.yp.to/cdb.html">cdb</a>.*/

@interface CDBReader : CDBFile 
{   @private struct cdb _cdb; }

/** Creates a CDBReader on an existing CDB file.
    The file must exist, but it is not opened or read from until the -open method is called. */
- (id) initWithFile: (NSString*)path;

/** Returns a pointer to the value associated with the key.
    (If there is none, the return value will have bytes=NULL and length=0.)
    You can use the CDBTo... utility functions to convert the value to NSData or NSString.
    This points directly into the memory-mapped file, without any copying, so it's very
    efficient. But the memory pointed to only remains valid until the CDBReader is closed! */
- (CDBData) valuePointerForKey: (CDBData)key;

/** Returns an enumerator that will return all of the keys, in unspecified order. */
- (CDBEnumerator*) keyEnumerator;

@end



/** Writes out new CDB files.
    This is a thin Objective-C wrapper around Michael Tokarev's 
    <a href="http://www.corpit.ru/mjt/tinycdb.html">tinycdb</a> library,
    which is itself a rewrite of Dan Bernstein's <a href="http://cr.yp.to/cdb.html>cdb</a>.*/

@interface CDBWriter : CDBFile 
{   @private struct cdb_make _cdbmake; }

/** Creates a CDBWriter that will generate a new CDB file at the given path.
    The file is not accessed until -open is called; then it will be created or truncated
    if necessary. */
- (id) initWithFile: (NSString*)path;

/** Writes a key/value pair to the file. Writing the same key twice is legal,
    but will waste the disk space that was occupied by the first value. */
- (BOOL) addValuePointer: (CDBData)value forKey: (CDBData)key;

/** Adds a key/value pair to the file, where the value is written from one or more
    discontiguous memory blocks.
    This has the same effect as the regular addValuePointer:forKey: method, but saves memory
    and time if the value needs to be assembled from multiple pieces.
    For example, CDBStore uses this call internally to prefix the user-supplied value with
    a tag byte, without having to copy the tag and value into a temporary buffer. */
- (BOOL) addValuePointers: (const CDBData[])values count: (unsigned)count forKey: (CDBData)key;

@end



/** Enumerator for key/value pairs in a CDBReader.
    Returned from -[CDBReader keyEnumerator]. */
@interface CDBEnumerator : NSEnumerator
{
    @private
    CDBReader *_db;
    struct cdb *_cdb;
    unsigned int _seq;
    CDBData _key, _value;
}

/** Standard NSEnumerator method; returns the next key copied into an NSData object. */
- (id) nextObject;

/** Advances to the next item, without returning the key as an object.
    This is slightly faster, if you don't need the key in that form.
    You can then access the keyPointer or valuePointer properties to read the key/value.
    @return  YES on success, or NO at the end. */
- (BOOL) next;

/** A direct pointer to the current key.
    This points directly into the memory-mapped file, without any copying, so it's very
    efficient. But the memory pointed to only remains valid until the CDBReader is closed.
    Before the first call to -next or -nextObject, this will point to NULL. */
@property (readonly) CDBData keyPointer;

/** A direct pointer to the current value.
    This points directly into the memory-mapped file, without any copying, so it's very
    efficient. But the memory pointed to only remains valid until the CDBReader is closed.
    Before the first call to -next or -nextObject, this will point to NULL. */
@property (readonly) CDBData valuePointer;

@end
