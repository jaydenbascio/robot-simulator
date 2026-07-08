# C++ Coding and Documentation Style Guide

This document defines the coding standards and documentation rules for this repository. Adopting a consistent style can improve readability, maintainability, and consistency across all modules.

## General Naming Conventions

### Classes
Class names should use `PascalCase`, with each word capitalized and no underscores.
```c++
class MyAwesomeClass {

};
```

### Functions and Methods

- Function names should always use `PascalCase`, with the exception of the `main` function located in `main.cpp`.
- Arguments should use `camelCase`

```c++
void MyAwesomeFunction(int argOne, int argTwo);

void MyAwesomeClass::PrintAmazingThings();
```

### Variables

#### Local variables
Local variables should always use `camelCase`.
```c++
int myValue = 0;
```

#### Class variables
- Private and protected variables use the form `m_` followed by `PascalCase`
- Public variables use `camelCase`

```c++
class MyAwesomeClass {
public:
    int publicVariable;

protected:
    int m_ProtectedVariable;

private:
    int m_PrivateVariable;
};
```

#### Constants
- Constants should be in the form of a `k` followed by the variable name in `PascalCase`.
```c++
constexpr int kMyConstant = 5;
```

#### Global Variables
Do not use global variables. Period.


### File / Folder Names
- Folders should be written in lowercase, and separated by underscores (e.g. `network_protocols`)
- Files related to a class should have the name of that class (e.g. `MyAwesomeClass.cpp`)
    - Test files should also include a `_test` at the end, such as `MyAwesomeClass_test.cpp`
- Files which do not relate to a class (e.g. for entry point or configuration constants) should be written in all lowercase, separated by underscores, similar to folders (e.g. `global_constants.cpp`)
```
my-awesome-project/
├── src/
│   ├── main.cpp
│   ├── network_protocols/
│   │   ├── PacketParser.cpp
│   │   ├── HttpClient.cpp
│   └── utilities/
│       ├── string_helpers.cpp
```

## File Structure and Layout
### Header Guards
- All `.h` files are required to use `#ifndef` guards to prevent duplication.
- The name of the macro used for a guard should be the file path (relative to `src`) written in `SCREAMING_SNAKE_CASE`, follwed by a `_H`.
- The `#endif` at the end of the file requires a comment specifying the macro name mentioned above
```c++
// File include/network_protocols/HttpClient.h

#ifndef NETWORK_PROTOCOLS_HTTP_CLIENT_H
#define NETWORK_PROTOCOLS_HTTP_CLIENT_H

...some code...

#endif // NETWORK_PROTOCOLS_HTTP_CLIENT_H
```

### Include Ordering
`#include` directives at the start of a file should be ordered as follows:
1. The header for this `.cpp` file (for `.cpp` files)
2. Your project's other `.h` files
3. Other libraries' `.h` files (e.g. for SDL3)
4. C++ standard libraries (e.g. `<vector>` or `<memory>`)
5. C system libraries (e.g. `<math.h>` or `<time.h>`)

Directives from seperate groups should be separated by an additional newline.
```c++
#include "network_protocols/HttpClient.h"

#include "utilities/string_helpers.h"
#include "utilities/math_helpers.h"

#include "SDL3/SDL3.h"

#include <vector>
#include <memory>

#include <math.h>

```

## Formatting and Whitespace
### Brace style
Use `K&R` style for braces, with the opening brace on the same line:

```c++
bool MyAwesomeClass::RealityWorks() {
    if (1 > 0) {
        return true;
    } else {
        return false;
    }
}
```

### Indentation and Spacing
- Use 4 spaces for indentations.
- Line lengths may not exceed 120 characters per line. Try to keep it under 80.
```c++
if (
    veryLongBooleanExpressionWhichIRepresentAsVariable &&
    otherVeryLongBooleanExpressionToMakeMyPoint &&
    seeHowIUsedNewlinesToShortenEachLine &&
    nowTheCodeIsSplitUpInsteadOfCrammedIntoASingleLine
) {}
```

### Pointer and Reference Alignment
Asterisks (`*`) and ampersands (`&`) should be placed directly to the right of the type name to denote pointers and references respectively.

```c++
int* myPointer;
int& myReference;
int** myDoublePointer;
```

### Const Alignment
When declaring variables or types, `const` should always be placed before the type name, so called the `West Const` style:

```c++
bool printString(const char *myString) {
    ...some code...
}
```

## Memory and Resource Management
### Memory Allocation and RAII
- The use of `malloc`, `free`, `new`, and `delete` is prohibited
- Always use smart pointers to guarantee RAII
- The choice between smart pointers should not be arbitrary
    - Choose `std::unique_ptr` as the default smart pointer
    - Choose `std::shared_ptr` only when a resource must be shared among multiple owners, and its lifetime cannot be managed by a single component
- Use `std::make_unique` and `std::make_shared` to optimize memory allocation and eliminate the use of `new`

```c++
/* IGNORE THE LACK OF DOXYGEN COMMENTS FOR DEMONSTRATION PURPOSES */

class Graphics {
private:
    // Graphics class completely owns the rendering pipeline
    // No other component should control its lifetime
    std::unique_ptr<Renderer> m_RenderPipeline;

    // A default texture is loaded once and shared across multiple objects
    // It stays alive as long as Graphics or any object is using it
    std::shared_ptr<Texture> m_DefaultTexture;
};
```

### Raw Pointers
- Raw pointers must NEVER represent ownership and should NEVER be used with `new` or `delete`
- Raw pointers are only acceptable as "observers" to pass a reference down a call stack when the target object is nullable and guarenteed to outlive the scope. If the object cannot be null, pass by reference (`&`) instead.

```c++
// Acceptable: this function does not manage life cycle; data is observing pointer
void ProcessData(const data_struct_t *data) {
    if (data) {
        data->Process();
    }
}
```

## Modern C++ and Tooling

### Value of null
The use of `0` or `NULL` for pointers is prohibited; use `nullptr` instead.

### Use of `auto`
Only use the `auto` keyword when the type is very obvious OR when the type is extremely complex, like the case for iterators.

```c++
// Bad usage; return type of addNumbers is not clear
auto myValue = addNumbers(5, 10);

// Good usage; type is obviously of shared_ptr<Widget>
auto myWidget = std::make_shared<Widget>();
```

### Casting values
- C-style casts such as `(double)5` are prohibited
- Use `static_cast` only when you are 100% sure the cast is safe and valid at compile-time
- Use `dynamic_cast` when you are working with polymorphic objects and can't be sure what the underlying object is.

```c++
// Standard type conversion; use static_cast
int piRoundedDown = static_cast<int>(std::acos(-1));

// Type of myObject is unknown; use dynamic_cast
if (Derived *derPtr = dynamic_cast<Derived*>(basePtr)) {
    derPtr->AwesomeFunction();
}
```

## Documentation and Comments
### Doxygen Style for Headers
All public headers, classes, and methods must be documented using Doxygen blocks (`/** */` or `///`). Doxygen blocks should NOT be placed in source files.
- Every public class and function must have a `@brief` description.
- Every public function must document every parameter using `@param` and return values using `@return`.
```c++
/// @brief Represents a client connection for handling HTTP requests
class HttpClient {
    public:
        /**
         * @brief Sends a GET request to the specified URL
         * @param url The URL to send the GET request to
         * @return Whether or not the request succeeded
         */
        bool SendGetRequest(const std::string& url);
};
```

### Implementation Comments
Inside function bodies, use standard single-line comments (`//`).
- Do not state the obvious (e.g. `// Increment i by 1`)
- Comment why something complex or not obvious is happening, not what the syntax is doing

```c++
// Bad: Duh, this is obvious.
int x = 10; // Initialize x to have a value of 10

// Good: Oh, that's what it does!
// Add random noise to simulate wheel slippage
particle.x += MathHelpers::RandomValue(-5.0f, 5.0f);
```
