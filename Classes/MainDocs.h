/*
 *  MainDocs.h
 *  CDBStore
 *
 *  Created by Jens Alfke on 3/6/08.
 *  Copyright 2008 Jens Alfke. All rights reserved.
 *
 */

// This file just contains the Doxygen comments that generate the main (index.html) page content.


/*! \mainpage CDBStore: A fast 'n' easy persistent storage library for Cocoa 
 
    \section intro_sec Introduction
 
    CDBStore is a small Objective-C library for efficiently storing data in semi-structured files.
    Its basic data model is a persistent dictionary: within a file, data values are associated with keys; and
    given a key, the value can be fetched quickly.
 
    Why use CDBStore instead of built-in storage mechanisms like property lists or Core Data?
    Because it occupies what I think is a sweet spot in between the two. 
        <ul>
        <li>Compared to a property
         list, CDBStore is more flexible in the types of values it can store, and it scales much better
         as the number of values grows. (Values are only read into memory on demand.)
        <li>Compared to CoreData, CDBStore is much simpler to understand,
         makes fewer demands on how you structure your code, and is likely to be more lightweight for
         smaller data sets.
        </ul>
 
     Why should you <i>not</i> use CDBStore?
     <ul>
     <li> Because your data set is so small and simple that it's just as easy to use a property list.
     <li> Because your data set is both very large [tens of megabytes] <i>and</i> changes frequently.
     <li> Because your data set requires complex queries.
     <li> Because CDBStore isn't as thoroughly tested as the alternatives.
     </ul>
 
 \section download How To Get It
 
    <ul>
    <li><a href="http://mooseyard.com/hg/hgwebdir.cgi/CDBStore/archive/tip.zip">Download the current source code</a>
 <li>To check out the source code using <a href="http://selenic.com/mercurial">Mercurial</a>:
     \verbatim hg clone http://mooseyard.com/hg/hgwebdir.cgi/CDBStore/ CDBStore \endverbatim
 </ul>
 
 Or if you're just looking:
 
 <ul>
 <li><a href="http://mooseyard.com/hg/hgwebdir.cgi/CDBStore/file/tip">Browse the source code</a>
 <li><a href="annotated.html">Browse the class documentation</a>
</ul>
 
 \section license License
 
 CDBStore is made available under a BSD license, so it may be used in commercial or free software.
 
 The underlying <a href="http://www.corpit.ru/mjt/tinycdb.html">tinycdb</a> library (included)
 is in the public domain.
 
 \section usage How To Use It
 
 You'll probably want to use the highest-level interface, the CDBStore class. Instances of this
 mimic mutable dictionaries. You just open a CDBStore on a file (which doesn't have to exist yet),
 use familiar NSMutableDictionary methods to store values for keys, and then call -save to write
 the changes to disk.
 
 However, CDBStore is more limited than a regular in-memory NSDictionary in what object types it supports.
 By default, the keys must be 
 NSData or NSString objects. The values can be of any archivable class (one that implements
 the NSCoding protocol.)
 
 It's possible to extend the supported key and value types. You just have to subclass CDBStore
 and override a few methods that convert between object pointers (id) and raw binary data.
 
 \subsection reader_writer CDBReader and CDBWriter
 
 On the other hand, if you only need to access keys and values as binary data (blobs), you might
 want to use the lower-level CDBReader and CDBWriter classes instead, as they have a bit less overhead.
 These classes are just thin Objective-C wrappers around the tinycdb (q.v.) API.
 
 CDBReader provides read-only access to an existing cdb file. You can look up the data value
 associated with a key, and you can enumerate all of the key-value pairs. That's all.
 
 CDBWriter is the write-only counterpart. You feed it key-value pairs one at a time, and it
 writes them to a new cdb file. After the file is complete, it can be accessed with CDBReader.
 
    \section how_it_works How It Works
 
 \subsection cdb CDB: A Constant Database
 
 CDBStore is based on Michael Tokarev's 
 <a href="http://www.corpit.ru/mjt/tinycdb.html">tinycdb</a> library,
 which is itself a rewrite of Dan Bernstein's original <a href="http://cr.yp.to/cdb.html">cdb</a>.
 In a nutshell, a cdb file is an on-disk hashtable, somewhat like the better-known Berkeley DB.
 The difference is that cdb is <i>read-only</i>, and optimized for fast access. The cdb home page
 lists the advantages:
 
    <div><i>
    <ul>
    <li>
    <b>Fast lookups:</b> A successful lookup in a large database normally takes
    just two disk accesses. An unsuccessful lookup takes only one.
    <li>
    <b>Low overhead:</b> A database uses 2048 bytes, plus 24 bytes per record,
    plus the space for keys and data.
    <li>
    <b>No random limits:</b> cdb can handle any database up to 4 gigabytes. There
    are no other restrictions; records don't even have to fit into memory.
    Databases are stored in a machine-independent format.
    <li>
    <b>Fast atomic database replacement:</b> cdbmake can rewrite an entire
    database two orders of magnitude faster than other hashing packages.
    </ul>
    </i></div> 
 
 In addition, the tinycdb implementation memory-maps the file, which means it benefits from the kernel's
 unified buffer cache, and avoids allocating memory in your heap, even when reading values. This can
 greatly improve memory usage with large files.
 
 As I said above, the CDBReader and CDBWriter classes are just simple object-oriented wrappers
 around the tinycdb API. There's nothing exciting about their implementation.
 
 \subsection cdbstore CDBStore: The Illusion Of Mutability
 
 The CDBStore class uses both CDBReader and CDBWriter, and adds two useful abstractions on top:
 objects for keys and values, and updating a database in place.
 
 To support key and value objects, CDBStore just uses two pairs of methods to encode and decode
 keys and values. The key codec just copies the bytes into and out of NSData objects. The
 value codec uses NSKeyedArchiver and NSKeyedUnarchiver (plus some special cases to more efficiently
 handle common types like NSData, NSString and NSValue.)
 
 To support incremental updates, CDBStore keeps an in-memory NSMutableDictionary to store unsaved
 changes; its lookup code checks this dictionary first before hitting the cdb file. (This dictionary
 is also used as a read cache, to avoid the expense of unarchiving objects multiple times.)
 To save changes, it first opens a CDBWriter on a new temporary file. Then it enumerates over the
 original file, copying the old value bytes directly across for an unmodified key, or archiving
 the object value for a modified key. Deleted keys are skipped. Then newly-added keys and values
 are written. Finally, the new file atomically replaces the old one.
 
 This is a "safe-save" technique. It has the advantage that the file can't be corrupted due to a
 crash, kernel panic or power failure, since the old file remains in place until the new one is
 complete. (Incrementally-updated files like SQL databases or Berkeley DBs can't make that claim.)
 But it has the disadvantage that the entire file has to be copied on save, even if only a tiny
 part of it changed. This could be a problem if you have a very large, frequently-changing file.
 
*/
